//go:build ios || darwin

package mobile

import (
	"core"
	"encoding/json"
	"runtime"
	"runtime/debug"
	"sync"
	"time"
)

var (
	iosInitOnce sync.Once
	iosEventMu  sync.RWMutex
	iosListener EventListener
)

// EventListener receives asynchronous JSON event batches from the Go core on iOS.
type EventListener interface {
	OnEvent(data string) error
}

// InitIOSMemoryLimit configures aggressive GC and memory bounds for iOS.
// Pass isExtension=true when running inside NEPacketTunnelProvider (50 MB system limit),
// or isExtension=false when running in-process inside the main Runner app (Free Apple ID mode).
func InitIOSMemoryLimit(isExtension bool) {
	iosInitOnce.Do(func() {
		if isExtension {
			// iOS NetworkExtension hard ceiling is 50 MB; cap Go heap around 32 MB
			debug.SetMemoryLimit(32 * 1024 * 1024)
			debug.SetGCPercent(20)
		} else {
			// Main app process has generous memory; cap at 256 MB
			debug.SetMemoryLimit(256 * 1024 * 1024)
			debug.SetGCPercent(50)
		}
		go func() {
			ticker := time.NewTicker(15 * time.Second)
			defer ticker.Stop()
			for range ticker.C {
				debug.FreeOSMemory()
			}
		}()
	})
}

// SetIOSEventListener registers the Swift/ObjC event callback bridge.
func SetIOSEventListener(listener EventListener) {
	iosEventMu.Lock()
	iosListener = listener
	iosEventMu.Unlock()
	if listener == nil {
		core.SetIOSEventListenerCore(nil)
		return
	}
	core.SetIOSEventListenerCore(func(data []byte) {
		iosEventMu.RLock()
		current := iosListener
		iosEventMu.RUnlock()
		if current != nil {
			_ = current.OnEvent(string(data))
		}
	})
}

// InvokeCoreMethod dispatches a FlClash MethodChannel-style JSON envelope
// {"id": "...", "method": "...", " params": ...} to core/method.go and returns the JSON response.
func InvokeCoreMethod(payload string) string {
	// Forwards directly to core.HandleMethodCallJSON exposed in core/lib_ios.go
	return handleIOSMethodCall(payload)
}

// StartIOSTun attaches Mihomo's sing-tun stack to the NEPacketTunnelProvider file descriptor.
func StartIOSTun(fd int32, mtu int32, stack string, dnsAddress string) string {
	err := startIOSTunWithFD(int(fd), int(mtu), stack, dnsAddress)
	if err != nil {
		resp, _ := json.Marshal(map[string]any{
			"ok":    false,
			"error": err.Error(),
		})
		return string(resp)
	}
	resp, _ := json.Marshal(map[string]any{"ok": true})
	return string(resp)
}

// StopIOSTun cleanly shuts down the active TUN interface in the NetworkExtension.
func StopIOSTun() {
	stopIOSTunInternal()
	runtime.GC()
	debug.FreeOSMemory()
}

// ForceIOSGC triggers an immediate garbage collection and returns OS pages.
func ForceIOSGC() {
	runtime.GC()
	debug.FreeOSMemory()
}

func handleIOSMethodCall(payload string) string {
	return core.HandleIOSMethodCallJSON(payload)
}

func startIOSTunWithFD(fd, mtu int, stack, dnsAddress string) error {
	return core.StartIOSTunDescriptor(fd, mtu, stack, dnsAddress)
}

func stopIOSTunInternal() {
	core.StopIOSTunDescriptor()
}
