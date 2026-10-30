//go:build ios || darwin

package core

import (
	"encoding/json"
	"fmt"
	"net"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	t "core/tun"

	"github.com/metacubex/mihomo/listener/sing_tun"
)

const (
	iosCallTimeout = 60 * time.Second
	iosTunAddress  = "198.18.0.1/30"
	iosTunMTU      = 1400
	iosTunStack    = "gvisor"
)

var (
	iosTunMu       sync.Mutex
	iosTunListener *sing_tun.Listener
)

// HandleIOSMethodCallJSON is lib.go's InvokeMethod for Apple platforms: a
// gomobile export must answer synchronously, and a wedged handler may not hang
// the Flutter isolate forever.
func HandleIOSMethodCallJSON(raw string) (out string) {
	defer func() {
		if r := recover(); r != nil {
			out = string(iosErrorResponse("internal_error", fmt.Sprintf("internal panic: %v", r)))
		}
	}()
	replies := make(chan []byte, 1)
	InvokeMethodIOS(raw, func(data []byte) {
		select {
		case replies <- data:
		default:
		}
	})
	select {
	case data := <-replies:
		return string(data)
	case <-time.After(iosCallTimeout):
		return string(iosErrorResponse("timeout", "core call timed out"))
	}
}

func InvokeMethodIOS(raw string, reply func([]byte)) {
	call := &MethodCall{}
	if err := json.Unmarshal([]byte(raw), call); err != nil {
		reply(encodeResponse(MethodResponse{Error: &MethodError{
			Code:    "invalid_method_call",
			Message: err.Error(),
		}}))
		return
	}
	dispatchMethodCall(call, reply)
}

// StartIOSTunDescriptor hands NEPacketTunnelProvider's utun descriptor to
// sing-tun. iOS sets up routes and DNS itself and exposes no per-socket protect
// hook, so none of Android's callbacks apply.
func StartIOSTunDescriptor(fd, mtu int, stack, dns string) error {
	if fd <= 0 {
		return fmt.Errorf("invalid utun file descriptor: %d", fd)
	}
	if mtu <= 0 {
		mtu = iosTunMTU
	}
	if stack == "" {
		stack = iosTunStack
	}
	options, err := json.Marshal(map[string]any{
		"mtu":                   mtu,
		"congestion-controller": "",
	})
	if err != nil {
		return err
	}
	iosTunMu.Lock()
	defer iosTunMu.Unlock()
	stopIOSTunLocked()
	listener := t.Start(fd, stack, iosTunAddress, normalizeIOSDNS(dns), string(options))
	if listener == nil {
		return fmt.Errorf("sing-tun rejected the utun descriptor %d", fd)
	}
	iosTunListener = listener
	if isRunning.Load() {
		handleResetConnections()
		bumpRouteEpoch()
		return nil
	}
	if !handleStartListener() {
		stopIOSTunLocked()
		return fmt.Errorf("core rejected the tun descriptor %d", fd)
	}
	return nil
}

func StopIOSTunDescriptor() {
	iosTunMu.Lock()
	stopIOSTunLocked()
	iosTunMu.Unlock()
	if isRunning.Load() {
		handleStopListener()
	}
	runtime.GC()
	debug.FreeOSMemory()
}

func stopIOSTunLocked() {
	if iosTunListener == nil {
		return
	}
	if err := iosTunListener.Close(); err != nil {
		logError("close ios tun listener: %v", err)
	}
	iosTunListener = nil
}

func SetIOSEventListenerCore(listener func([]byte)) {
	setAppleEventSink(listener)
}

// normalizeIOSDNS accepts "198.18.0.2:53" or "1.1.1.1,8.8.8.8" and yields the
// bare address list sing-tun builds its hijack targets from.
func normalizeIOSDNS(raw string) string {
	servers := make([]string, 0, 2)
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if host, _, err := net.SplitHostPort(part); err == nil && host != "" {
			part = host
		}
		servers = append(servers, part)
	}
	return strings.Join(servers, ",")
}

func iosErrorResponse(code, message string) []byte {
	payload, err := json.Marshal(MethodResponse{Error: &MethodError{Code: code, Message: message}})
	if err != nil {
		return []byte(`{"error":{"code":"internal_error","message":"encode response"}}`)
	}
	return payload
}
