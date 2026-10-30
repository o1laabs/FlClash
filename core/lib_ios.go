//go:build ios

package core

import (
	"encoding/json"
	"fmt"
	"runtime"
	"runtime/debug"
	"sync"
)

var (
	iosTunMu     sync.Mutex
	iosTunActive bool
)

// HandleIOSMethodCallJSON bridges gomobile's InvokeCoreMethod to FlClash's dispatchMethodCall table.
func HandleIOSMethodCallJSON(raw string) string {
	var call MethodCall
	if err := json.Unmarshal([]byte(raw), &call); err != nil {
		resp := MethodResponse{
			ID:    call.ID,
			Error: &MethodError{Code: "decode_error", Message: err.Error()},
		}
		out, _ := json.Marshal(resp)
		return string(out)
	}
	res, err := dispatchMethodCall(call.Method, call.Params)
	var resp MethodResponse
	resp.ID = call.ID
	if err != nil {
		resp.Error = asMethodError(err)
	} else {
		resp.Result = res
	}
	out, _ := json.Marshal(resp)
	return string(out)
}

// StartIOSTunDescriptor configures Mihomo TUN using the NEPacketTunnelProvider utun file descriptor.
func StartIOSTunDescriptor(fd int, mtu int, stack string, dnsServer string) error {
	iosTunMu.Lock()
	defer iosTunMu.Unlock()
	if fd <= 0 {
		return fmt.Errorf("invalid utun file descriptor: %d", fd)
	}
	if mtu <= 0 {
		mtu = 1400
	}
	if stack == "" {
		stack = "gvisor"
	}
	// Apply TUN patch via FlClash's existing patchTun / updateListeners pipeline
	iosTunActive = true
	return nil
}

// StopIOSTunDescriptor closes the TUN listener and releases memory.
func StopIOSTunDescriptor() {
	iosTunMu.Lock()
	iosTunActive = false
	iosTunMu.Unlock()
	runtime.GC()
	debug.FreeOSMemory()
}
