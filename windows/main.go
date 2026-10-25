//go:build windows

// wipe — lock the keyboard (and optionally blank the screen) while you clean your PC.
//
// Uses a low-level keyboard hook, so every key is swallowed before Windows acts on it,
// including the Windows key, Alt+Tab and media keys. Two things can't be blocked:
// Ctrl+Alt+Del (the OS reserves it) and laptop brightness keys that the firmware
// handles itself.
//
// The hook runs on its own thread so drawing the UI can never hold up the keyboard, and a
// watchdog lets go of everything if the UI thread ever stops responding.
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const version = "0.5.0"

func init() { runtime.LockOSThread() } // the screen window belongs to the main thread

// ---------- style ----------

const (
	esc     = "\x1b["
	reset   = esc + "0m"
	bold    = esc + "1m"
	accentN = 173 // terracotta; reads on light and dark terminal themes
)

func fg(n int) string { return esc + "38;5;" + strconv.Itoa(n) + "m" }

var (
	accent = fg(accentN)
	muted  = fg(245)
	faint  = fg(240)
)

var spinner = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

func duration(d time.Duration) string {
	s := int(d / time.Second)
	if s < 60 {
		return fmt.Sprintf("%ds", s)
	}
	return fmt.Sprintf("%dm %ds", s/60, s%60)
}

// ---------- key names (for wipe configure) ----------

var (
	keyLabels = map[uint32]string{
		0x70: "F1", 0x71: "F2", 0x72: "F3", 0x73: "F4", 0x74: "F5", 0x75: "F6", 0x76: "F7", 0x77: "F8",
		0x78: "F9", 0x79: "F10", 0x7A: "F11", 0x7B: "F12",
		0xC0: "`", 0xBD: "-", 0xBB: "=", 0xDB: "[", 0xDD: "]", 0xDC: "\\", 0xBA: ";", 0xDE: "'", 0xBC: ",", 0xBE: ".", 0xBF: "/",
		0x1B: "esc", 0x09: "tab", 0x20: "space", 0x0D: "enter", 0x08: "bksp", 0x25: "←", 0x26: "↑", 0x27: "→", 0x28: "↓",
	}
	modifiers = map[uint32]bool{0x10: true, 0x11: true, 0x12: true, 0xA0: true, 0xA1: true, 0xA2: true, 0xA3: true,
		0xA4: true, 0xA5: true, 0x5B: true, 0x5C: true}
)

func init() {
	for c := uint32('0'); c <= '9'; c++ {
		keyLabels[c] = string(rune(c))
	}
	for c := uint32('A'); c <= 'Z'; c++ {
		keyLabels[c] = string(rune(c))
	}
}

// ---------- exit shortcut (wipe configure) ----------

type combo struct {
	Ctrl  bool   `json:"ctrl"`
	Shift bool   `json:"shift"`
	Alt   bool   `json:"alt"`
	Win   bool   `json:"win"`
	Key   uint32 `json:"key"`
	Label string `json:"label"`
}

func (c combo) text() string {
	var p []string
	if c.Ctrl {
		p = append(p, "ctrl")
	}
	if c.Alt {
		p = append(p, "alt")
	}
	if c.Shift {
		p = append(p, "shift")
	}
	if c.Win {
		p = append(p, "win")
	}
	return strings.Join(append(p, c.Label), " + ")
}

var defaultCombo = combo{Ctrl: true, Shift: true, Key: 'X', Label: "X"}

func configPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = os.Getenv("APPDATA")
	}
	return filepath.Join(dir, "wipe", "config.json")
}

func loadCombo() combo {
	c := defaultCombo
	if data, err := os.ReadFile(configPath()); err == nil {
		if json.Unmarshal(data, &c) != nil || c.Key == 0 {
			c = defaultCombo
		}
	}
	return c
}

func saveCombo(c combo) {
	os.MkdirAll(filepath.Dir(configPath()), 0o755)
	data, _ := json.MarshalIndent(c, "", "  ")
	os.WriteFile(configPath(), data, 0o644)
}

var exitCombo = loadCombo()

// ---------- options ----------

type mode int

const (
	modeNone mode = iota
	modeKeyboard
	modeBlack
	modeWhite
)

func (m mode) title() string {
	return map[mode]string{modeKeyboard: "keyboard", modeBlack: "black screen", modeWhite: "white screen"}[m]
}

var (
	startMode     mode
	configureOnly bool
	preview       bool // show the keyboard screen and a pretend exit hold; nothing is locked
	timeout       = 120 * time.Second
	holdSeconds   = time.Second
)

func usage() {
	fmt.Print("\n" +
		"   " + accent + "●" + reset + " " + bold + "wipe" + reset + "  " + muted + "clean your PC without shutting it down · v" + version + reset + "\n\n" +
		"   " + bold + "wipe" + reset + "                  " + muted + "pick a mode from a menu" + reset + "\n" +
		"   " + bold + "wipe screen black" + reset + "     " + muted + "black screen, keyboard locked" + reset + "\n" +
		"   " + bold + "wipe screen white" + reset + "     " + muted + "white screen, keyboard locked" + reset + "\n" +
		"   " + bold + "wipe keyboard" + reset + "         " + muted + "lock every key while you clean" + reset + "\n" +
		"   " + bold + "wipe configure" + reset + "        " + muted + "change the exit shortcut" + reset + "\n" +
		"   " + bold + "wipe preview" + reset + "          " + muted + "see the keyboard screen, nothing locked" + reset + "\n\n" +
		"   " + faint + "-t, --timeout <sec>   unlock by itself after this long (default 120)" + reset + "\n\n" +
		"   " + muted + "exit any mode: hold" + reset + " " + exitCombo.text() + " " + muted + "for a second" + reset + "\n\n")
	os.Exit(0)
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "wipe: "+msg)
	os.Exit(2)
}

func parseArgs() {
	args := os.Args[1:]
	for len(args) > 0 {
		a := args[0]
		args = args[1:]
		switch a {
		case "keyboard", "keys", "kb":
			startMode = modeKeyboard
		case "screen":
			startMode = modeBlack
			if len(args) > 0 && (args[0] == "black" || args[0] == "white") {
				if args[0] == "white" {
					startMode = modeWhite
				}
				args = args[1:]
			}
		case "black":
			startMode = modeBlack
		case "white":
			startMode = modeWhite
		case "configure", "--configure", "config":
			configureOnly = true
		case "preview":
			preview = true
		case "-t", "--timeout":
			if len(args) == 0 {
				fail("--timeout needs a number of seconds (at least 10)")
			}
			v, err := strconv.Atoi(args[0])
			if err != nil || v < 10 {
				fail("--timeout needs a number of seconds (at least 10)")
			}
			args = args[1:]
			timeout = time.Duration(min(v, 1800)) * time.Second
		case "-h", "--help", "help":
			usage()
		case "-v", "--version":
			fmt.Println(version)
			os.Exit(0)
		default:
			fail("unknown command '" + a + "'. Try 'wipe help'.")
		}
	}
}

// ---------- win32 ----------

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")

	pSetWindowsHookEx    = user32.NewProc("SetWindowsHookExW")
	pCallNextHookEx      = user32.NewProc("CallNextHookEx")
	pGetMessage          = user32.NewProc("GetMessageW")
	pPeekMessage         = user32.NewProc("PeekMessageW")
	pTranslateMessage    = user32.NewProc("TranslateMessage")
	pDispatchMessage     = user32.NewProc("DispatchMessageW")
	pSetTimer            = user32.NewProc("SetTimer")
	pRegisterClassEx     = user32.NewProc("RegisterClassExW")
	pCreateWindowEx      = user32.NewProc("CreateWindowExW")
	pDestroyWindow       = user32.NewProc("DestroyWindow")
	pShowWindow          = user32.NewProc("ShowWindow")
	pDefWindowProc       = user32.NewProc("DefWindowProcW")
	pSetLayeredAttrs     = user32.NewProc("SetLayeredWindowAttributes")
	pShowCursor          = user32.NewProc("ShowCursor")
	pSetCursor           = user32.NewProc("SetCursor")
	pGetSystemMetrics    = user32.NewProc("GetSystemMetrics")
	pSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	pGetForegroundWindow = user32.NewProc("GetForegroundWindow")
	pInvalidateRect      = user32.NewProc("InvalidateRect")
	pBeginPaint          = user32.NewProc("BeginPaint")
	pEndPaint            = user32.NewProc("EndPaint")
	pFillRect            = user32.NewProc("FillRect")
	pDrawText            = user32.NewProc("DrawTextW")
	pGetModuleHandle     = kernel32.NewProc("GetModuleHandleW")
	pGetStdHandle        = kernel32.NewProc("GetStdHandle")
	pGetConsoleMode      = kernel32.NewProc("GetConsoleMode")
	pSetConsoleMode      = kernel32.NewProc("SetConsoleMode")
	pSetConsoleOutputCP  = kernel32.NewProc("SetConsoleOutputCP")
	pFlushConsoleInput   = kernel32.NewProc("FlushConsoleInputBuffer")
	pCreateSolidBrush    = gdi32.NewProc("CreateSolidBrush")
	pCreatePen           = gdi32.NewProc("CreatePen")
	pSelectObject        = gdi32.NewProc("SelectObject")
	pDeleteObject        = gdi32.NewProc("DeleteObject")
	pGetStockObject      = gdi32.NewProc("GetStockObject")
	pEllipse             = gdi32.NewProc("Ellipse")
	pArc                 = gdi32.NewProc("Arc")
	pSetArcDirection     = gdi32.NewProc("SetArcDirection")
	pSetTextColor        = gdi32.NewProc("SetTextColor")
	pSetBkMode           = gdi32.NewProc("SetBkMode")
	pCreateFont          = gdi32.NewProc("CreateFontW")
)

const (
	whKeyboardLL = 13
	wmKeyDown    = 0x0100
	wmKeyUp      = 0x0101
	wmSysKeyDown = 0x0104
	wmSysKeyUp   = 0x0105
	wmTimer      = 0x0113
	wmPaint      = 0x000F
	wmEraseBkgnd = 0x0014
	wmSetCursor  = 0x0020
)

type kbdllhookstruct struct {
	vkCode, scanCode, flags, time uint32
	extra                         uintptr
}

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      [2]int32
	private uint32
}

type rect struct{ left, top, right, bottom int32 }

type paintstruct struct {
	hdc       uintptr
	erase     int32
	paint     rect
	restore   int32
	incUpdate int32
	reserved  [32]byte
}

type wndclassex struct {
	size       uint32
	style      uint32
	wndProc    uintptr
	clsExtra   int32
	wndExtra   int32
	instance   uintptr
	icon       uintptr
	cursor     uintptr
	background uintptr
	menuName   *uint16
	className  *uint16
	iconSm     uintptr
}

// ---------- terminal ----------

var (
	stdoutH, stdinH       uintptr
	oldOutMode, oldInMode uint32
	terminalWnd           uintptr                 // focus goes back here after a screen mode
	keys                  = make(chan string, 16) // key presses from the reader goroutine
)

func setupConsole() {
	stdoutH, _, _ = pGetStdHandle.Call(uintptr(^uint32(10))) // STD_OUTPUT_HANDLE (-11)
	stdinH, _, _ = pGetStdHandle.Call(uintptr(^uint32(9)))   // STD_INPUT_HANDLE (-10)
	pGetConsoleMode.Call(stdoutH, uintptr(unsafe.Pointer(&oldOutMode)))
	pGetConsoleMode.Call(stdinH, uintptr(unsafe.Pointer(&oldInMode)))
	pSetConsoleMode.Call(stdoutH, uintptr(oldOutMode|0x0004)) // ENABLE_VIRTUAL_TERMINAL_PROCESSING
	pSetConsoleOutputCP.Call(65001)
	terminalWnd, _, _ = pGetForegroundWindow.Call()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM) // SIGTERM: console window closed
	go func() {
		<-sig
		quit(0)
	}()
}

// rawInput turns off line buffering and echo and asks for VT sequences for arrow keys,
// then reads keys on a background goroutine so the UI can keep animating.
func rawInput() {
	pSetConsoleMode.Call(stdinH, 0x0200)
	go func() {
		buf := make([]byte, 16)
		for {
			n, err := os.Stdin.Read(buf)
			if err != nil {
				quit(0) // the console went away; don't linger in the background
			}
			if n > 0 {
				keys <- string(buf[:n])
			}
		}
	}()
}

// readKey waits up to d for a key; "" means nothing was pressed.
func readKey(d time.Duration) string {
	select {
	case k := <-keys:
		return k
	case <-time.After(d):
		return ""
	}
}

func flushKeys() {
	pFlushConsoleInput.Call(stdinH)
	for {
		select {
		case <-keys:
		default:
			return
		}
	}
}

func write(s string) { fmt.Print(s) }

func restoreTerminal() {
	pSetConsoleMode.Call(stdinH, uintptr(oldInMode))
	write(esc + "?25h")
	pSetConsoleMode.Call(stdoutH, uintptr(oldOutMode))
}

func quit(code int) {
	setHook(false)
	restoreTerminal()
	os.Exit(code)
}

func isTerminal() bool {
	var m uint32
	r, _, _ := pGetConsoleMode.Call(stdinH, uintptr(unsafe.Pointer(&m)))
	return r != 0
}

func eraseLines(n int) {
	if n > 0 {
		write(fmt.Sprintf("\r"+esc+"%dA"+esc+"J", n))
	} else {
		write("\r" + esc + "J")
	}
}

// ---------- shared state (written by the hook thread, read by the UI thread) ----------

var (
	mu             sync.Mutex
	hookReady      bool
	hookOn         bool
	heartbeat      time.Time // the UI thread bumps this every frame
	watchdogFired  bool
	down           = map[uint32]bool{} // keys held right now; the session ends once they're let go
	comboSince     time.Time
	releasingSince time.Time // exit reached; still swallowing until the keys are let go
	captureMode    bool      // wipe configure: grab the next shortcut instead
	captured       *combo

	startedAt time.Time
)

func resetSession() {
	mu.Lock()
	down = map[uint32]bool{}
	comboSince, releasingSince = time.Time{}, time.Time{}
	watchdogFired, heartbeat = false, time.Now()
	mu.Unlock()
	startedAt = time.Now()
}

// The helpers below expect mu to be held.
func isDown(vks ...uint32) bool {
	for _, v := range vks {
		if down[v] {
			return true
		}
	}
	return false
}

func currentMods() (ctrl, shift, alt, win bool) {
	return isDown(0x11, 0xA2, 0xA3), isDown(0x10, 0xA0, 0xA1), isDown(0x12, 0xA4, 0xA5), isDown(0x5B, 0x5C)
}

func comboHeld() bool {
	ctrl, shift, alt, win := currentMods()
	c := exitCombo
	return down[c.Key] && ctrl == c.Ctrl && shift == c.Shift && alt == c.Alt && win == c.Win
}

func hookProc(nCode int, wParam uintptr, lParam uintptr) uintptr {
	if nCode == 0 {
		kb := (*kbdllhookstruct)(unsafe.Pointer(lParam))
		mu.Lock()
		on := hookOn
		if on {
			vk := kb.vkCode
			isPress := wParam == wmKeyDown || wParam == wmSysKeyDown
			switch {
			case isPress:
				down[vk] = true
				if captureMode && captured == nil && !modifiers[vk] {
					ctrl, shift, alt, win := currentMods()
					label := keyLabels[vk]
					if label == "" {
						label = fmt.Sprintf("key %d", vk)
					}
					captured = &combo{ctrl, shift, alt, win, vk, label}
				}
			case wParam == wmKeyUp || wParam == wmSysKeyUp:
				delete(down, vk)
			}
			if comboHeld() && !captureMode {
				if comboSince.IsZero() {
					comboSince = time.Now()
				}
			} else {
				comboSince = time.Time{}
			}
		}
		mu.Unlock()
		if on {
			return 1 // swallow
		}
	}
	r, _, _ := pCallNextHookEx.Call(0, uintptr(nCode), wParam, lParam)
	return r
}

// startHookThread installs the hook on a dedicated thread with its own message loop, plus a
// watchdog that stops swallowing keys if the UI thread goes quiet for more than 2.5 seconds.
func startHookThread() bool {
	if hookReady {
		return true
	}
	ready := make(chan bool)
	go func() {
		runtime.LockOSThread()
		h, _, _ := pSetWindowsHookEx.Call(whKeyboardLL, syscall.NewCallback(hookProc), 0, 0)
		ready <- h != 0
		if h == 0 {
			return
		}
		pSetTimer.Call(0, 0, 500, 0)
		var m msg
		for {
			r, _, _ := pGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 {
				return
			}
			if m.message == wmTimer {
				mu.Lock()
				if hookOn && time.Since(heartbeat) > 2500*time.Millisecond {
					hookOn, watchdogFired = false, true
				}
				mu.Unlock()
			}
			pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
			pDispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
		}
	}()
	hookReady = <-ready
	return hookReady
}

func setHook(on bool) {
	mu.Lock()
	hookOn, heartbeat = on, time.Now()
	if !on {
		down = map[uint32]bool{}
	}
	mu.Unlock()
}

func ensureHook() {
	if !startHookThread() {
		write("   Windows didn't allow the keyboard lock. Try running the terminal as administrator.\n")
		quit(1)
	}
}

// ---------- wordmark ----------

// dot is the accent mark; it breathes on a two-second loop.
func dot(t float64) string {
	ramp := []int{173, 173, 174, 180, 216, 180, 174, 173}
	return fg(ramp[int(t*4)%len(ramp)]) + "●" + reset
}

// wordmark is "wipe  tagline" with a shine that sweeps across once, like the buttons on the site.
func wordmark(t float64, tagline string) string {
	text := []rune("wipe  " + tagline)
	p := (t-0.15)/0.7*float64(len(text)+8) - 4
	var b strings.Builder
	b.WriteString("   " + dot(t) + " ")
	for j, ch := range text {
		base := muted
		if j < 4 {
			base = bold
		}
		if math.Abs(float64(j)-p) < 2 {
			base = accent
			if j < 4 {
				base += bold
			}
		}
		b.WriteString(base + string(ch) + reset)
	}
	return b.String()
}

// ---------- configure ----------

func configure() {
	ensureHook()
	drawn := 0
	// show the outcome for a moment, then clear it so the menu comes back clean
	defer func() { time.Sleep(900 * time.Millisecond); eraseLines(drawn); flushKeys() }()
	show := func(lines []string) {
		var b strings.Builder
		if drawn > 0 {
			fmt.Fprintf(&b, "\r"+esc+"%dA", drawn)
		}
		for _, l := range lines {
			b.WriteString(l + esc + "K\n")
		}
		write(b.String() + esc + "J")
		drawn = len(lines)
	}
	header := []string{"", "   " + dot(0) + " " + bold + "wipe" + reset + "  " + muted + "exit shortcut" + reset, "",
		"   " + faint + "now" + reset + "   " + bold + exitCombo.text() + reset}
	with := func(extra ...string) []string { return append(append([]string{}, header...), extra...) }

	for {
		mu.Lock()
		captured, captureMode = nil, true
		mu.Unlock()
		setHook(true)
		var got *combo
		start := time.Now()
		for i := 0; got == nil && time.Since(start) < 30*time.Second; i++ {
			show(with("", "   "+accent+spinner[i%len(spinner)]+reset+" "+muted+"press the new shortcut — use ctrl, alt or win with a key"+reset, "", "   "+bold+"esc"+reset+" "+faint+"back"+reset))
			time.Sleep(80 * time.Millisecond)
			mu.Lock()
			heartbeat, got = time.Now(), captured
			mu.Unlock()
		}
		mu.Lock()
		captureMode = false
		mu.Unlock()
		setHook(false)
		time.Sleep(150 * time.Millisecond) // let the keys come up before reading the terminal again
		flushKeys()

		if got == nil {
			show(with("", "   "+muted+"nothing pressed — kept"+reset+" "+exitCombo.text(), ""))
			return
		}
		if got.Key == 0x1B && !(got.Ctrl || got.Shift || got.Alt || got.Win) {
			show(with("", "   "+muted+"back — kept"+reset+" "+exitCombo.text(), ""))
			return
		}
		if !(got.Ctrl || got.Alt || got.Win) {
			show(with("", "   "+accent+"!"+reset+" "+bold+got.text()+reset+" "+muted+"is too easy to hit while wiping — add ctrl, alt or win"+reset))
			time.Sleep(1600 * time.Millisecond)
			continue
		}

		show(with("", "   "+accent+"›"+reset+" "+faint+"new"+reset+"   "+bold+got.text()+reset, "",
			"   "+bold+"↵"+reset+" "+faint+"save"+reset+"   "+bold+"r"+reset+" "+faint+"try again"+reset+"   "+
				bold+"d"+reset+" "+faint+"default"+reset+"   "+bold+"esc"+reset+" "+faint+"back"+reset))
		retry := false
		for !retry {
			switch k := readKey(time.Second); k {
			case "\r", "\n":
				mu.Lock()
				exitCombo = *got
				mu.Unlock()
				saveCombo(exitCombo)
				show(append(header[:3:3], "   "+accent+"✓"+reset+" "+muted+"saved — hold"+reset+" "+bold+exitCombo.text()+reset+" "+muted+"to exit any mode"+reset, ""))
				return
			case "d":
				mu.Lock()
				exitCombo = defaultCombo
				mu.Unlock()
				saveCombo(exitCombo)
				show(append(header[:3:3], "   "+accent+"✓"+reset+" "+muted+"back to the default —"+reset+" "+bold+exitCombo.text()+reset, ""))
				return
			case "r":
				retry = true
			case "\x1b", "q", "\x03":
				show(with("", "   "+muted+"back — kept"+reset+" "+exitCombo.text(), ""))
				return
			}
		}
	}
}

// ---------- menu ----------

type item struct {
	title  string
	detail func() string
	mode   mode // modeNone = exit shortcut settings
}

var items = []item{
	{"Black screen", func() string { return "wipe screen black" }, modeBlack},
	{"White screen", func() string { return "wipe screen white" }, modeWhite},
	{"Keyboard", func() string { return "wipe keyboard" }, modeKeyboard},
	{"Exit shortcut", func() string { return exitCombo.text() + "  ·  wipe configure" }, modeNone},
}

// runMenu returns the picked item index, or -1 to quit.
func runMenu(sel int) int {
	drawn := 0
	last := ""
	t0 := time.Now()
	write(esc + "?25l")

	draw := func() {
		t := time.Since(t0).Seconds()
		lines := []string{"", wordmark(t, "clean without shutting down"), ""}
		for i, it := range items {
			if i == 3 {
				lines = append(lines, "")
			}
			title := it.title + strings.Repeat(" ", 16-len(it.title))
			if i == sel {
				lines = append(lines, "   "+accent+"›"+reset+" "+bold+title+reset+faint+it.detail()+reset)
			} else {
				lines = append(lines, "     "+muted+title+reset+faint+it.detail()+reset)
			}
		}
		lines = append(lines, "", "   "+faint+"↑↓ choose  ·  enter start  ·  q quit"+reset)

		// lines rise in one after another
		var b strings.Builder
		for i, line := range lines {
			if t < float64(i)*0.04 {
				line = ""
			}
			b.WriteString(line + esc + "K\n")
		}
		if b.String() == last {
			return
		}
		last = b.String()
		if drawn > 0 {
			write(fmt.Sprintf("\r"+esc+"%dA", drawn))
		}
		write(last)
		drawn = len(lines)
	}

	for {
		draw()
		switch k := readKey(40 * time.Millisecond); {
		case k == "":
		case k == "\x1b[A" || k == "k":
			sel = (sel + len(items) - 1) % len(items)
		case k == "\x1b[B" || k == "j":
			sel = (sel + 1) % len(items)
		case k == "\r" || k == "\n":
			eraseLines(drawn)
			return sel
		case k == "q" || k == "\x1b" || k == "\x03":
			eraseLines(drawn)
			return -1
		case len(k) == 1 && k[0] >= '1' && k[0] < '1'+byte(len(items)):
			eraseLines(drawn)
			return int(k[0] - '1')
		}
	}
}

type snap struct {
	down                       map[uint32]bool
	comboSince, releasingSince time.Time
}

func snapshot() snap {
	mu.Lock()
	defer mu.Unlock()
	s := snap{map[uint32]bool{}, comboSince, releasingSince}
	for k, v := range down {
		s.down[k] = v
	}
	return s
}

// ---------- screen mode ----------

var (
	classRegistered bool
	screenWnd       uintptr
	screenBrush     uintptr
	screenMode      mode
	hintFont        uintptr
	titleFont       uintptr
	hintText        string
	hintVisible     bool
	ringP           = -1.0 // <0 hides the ring
)

func sysMetric(i int) int {
	r, _, _ := pGetSystemMetrics.Call(uintptr(i))
	return int(int32(r))
}

func wndProc(hwnd uintptr, m uint32, wParam, lParam uintptr) uintptr {
	switch m {
	case wmSetCursor:
		pSetCursor.Call(0)
		return 1
	case wmEraseBkgnd:
		return 1 // painted in WM_PAINT, avoids flicker
	case wmPaint:
		var ps paintstruct
		hdc, _, _ := pBeginPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
		pFillRect.Call(hdc, uintptr(unsafe.Pointer(&ps.paint)), screenBrush)

		// primary monitor, in window coordinates
		vx, vy := int32(sysMetric(76)), int32(sysMetric(77))
		w, h := int32(sysMetric(0)), int32(sysMetric(1))
		ox, oy := -vx, -vy

		pSetBkMode.Call(hdc, 1) // TRANSPARENT
		text := func(s string, font, color uintptr, top int32) {
			pSelectObject.Call(hdc, font)
			pSetTextColor.Call(hdc, color)
			r := rect{ox, oy + top, ox + w, oy + top + 48}
			t, _ := syscall.UTF16PtrFromString(s)
			pDrawText.Call(hdc, uintptr(unsafe.Pointer(t)), ^uintptr(0), uintptr(unsafe.Pointer(&r)), 0x1|0x4|0x20)
		}

		// colors are 0xBBGGRR
		hintColor, track, bar := uintptr(0x606060), uintptr(0x303030), uintptr(0x9A9A9A)
		cy := oy + h/2
		switch screenMode {
		case modeWhite:
			hintColor, track, bar = 0x9E9E9E, 0xDDDDDD, 0x6E6E6E
		case modeKeyboard:
			hintColor, track, bar = 0x6E7378, 0x262728, 0x5C78CC // terracotta ring
			title := "Keyboard locked"
			if preview {
				title = "Keyboard locked (preview)"
			}
			text(title, titleFont, 0xDDE8EE, h/2-130)
			text("wipe away — nothing you press will do anything", hintFont, 0x7A7F84, h/2-78)
			cy += 30
		}
		if hintVisible {
			text(hintText, hintFont, hintColor, h-104)
		}

		if ringP >= 0 {
			cx, rad := ox+w/2, int32(34)
			nullBrush, _, _ := pGetStockObject.Call(5)
			oldBrush, _, _ := pSelectObject.Call(hdc, nullBrush)
			pen, _, _ := pCreatePen.Call(0, 4, track)
			oldPen, _, _ := pSelectObject.Call(hdc, pen)
			pEllipse.Call(hdc, uintptr(cx-rad), uintptr(cy-rad), uintptr(cx+rad), uintptr(cy+rad))
			pSelectObject.Call(hdc, oldPen)
			pDeleteObject.Call(pen)

			if ringP > 0.01 {
				pen, _, _ = pCreatePen.Call(0, 4, bar)
				pSelectObject.Call(hdc, pen)
				if ringP >= 0.999 {
					pEllipse.Call(hdc, uintptr(cx-rad), uintptr(cy-rad), uintptr(cx+rad), uintptr(cy+rad))
				} else {
					a := ringP * 2 * math.Pi
					ex := cx + int32(float64(rad)*math.Sin(a))
					ey := cy - int32(float64(rad)*math.Cos(a))
					pSetArcDirection.Call(hdc, 2) // AD_CLOCKWISE
					pArc.Call(hdc, uintptr(cx-rad), uintptr(cy-rad), uintptr(cx+rad), uintptr(cy+rad),
						uintptr(cx), uintptr(cy-rad), uintptr(ex), uintptr(ey))
				}
				pSelectObject.Call(hdc, oldPen)
				pDeleteObject.Call(pen)
			}
			pSelectObject.Call(hdc, oldBrush)
		}
		pEndPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
		return 0
	}
	r, _, _ := pDefWindowProc.Call(hwnd, uintptr(m), wParam, lParam)
	return r
}

func showScreen(m mode) {
	inst, _, _ := pGetModuleHandle.Call(0)
	className, _ := syscall.UTF16PtrFromString("WipeScreen")
	if !classRegistered {
		wc := wndclassex{wndProc: syscall.NewCallback(wndProc), instance: inst, className: className}
		wc.size = uint32(unsafe.Sizeof(wc))
		pRegisterClassEx.Call(uintptr(unsafe.Pointer(&wc)))
		face, _ := syscall.UTF16PtrFromString("Segoe UI")
		font := func(size, weight int) uintptr {
			f, _, _ := pCreateFont.Call(uintptr(-size), 0, 0, 0, uintptr(weight), 0, 0, 0, 1, 0, 0, 5, 0, uintptr(unsafe.Pointer(face)))
			return f
		}
		hintFont, titleFont = font(15, 500), font(34, 600)
		classRegistered = true
	}
	screenMode = m
	color := map[mode]uintptr{modeBlack: 0x000000, modeWhite: 0xFFFFFF, modeKeyboard: 0x111213}[m]
	if screenBrush != 0 {
		pDeleteObject.Call(screenBrush)
	}
	screenBrush, _, _ = pCreateSolidBrush.Call(color)
	hintText, hintVisible, ringP = "hold  "+exitCombo.text()+"  to exit", true, -1

	// One window over the whole virtual desktop covers every monitor.
	x, y := sysMetric(76), sysMetric(77)
	w, h := sysMetric(78), sysMetric(79)
	title, _ := syscall.UTF16PtrFromString("wipe")
	screenWnd, _, _ = pCreateWindowEx.Call(
		0x8|0x80|0x80000, // WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED (for the fade)
		uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(title)),
		0x80000000, // WS_POPUP
		uintptr(x), uintptr(y), uintptr(w), uintptr(h), 0, 0, inst, 0)
	setAlpha(0)
	pShowWindow.Call(screenWnd, 5) // SW_SHOW
	pSetForegroundWindow.Call(screenWnd)
	pShowCursor.Call(0)
}

func setAlpha(a float64) {
	pSetLayeredAttrs.Call(screenWnd, 0, uintptr(max(0, min(255, int(a*255)))), 0x2) // LWA_ALPHA
}

// updateScreen changes the hint and ring, repainting only when something moved.
func updateScreen(text string, visible bool, p float64) {
	if p >= 0 {
		p = math.Round(p*60) / 60
	}
	if text == hintText && visible == hintVisible && p == ringP {
		return
	}
	hintText, hintVisible, ringP = text, visible, p
	pInvalidateRect.Call(screenWnd, 0, 0)
}

func pump() {
	var m msg
	for {
		r, _, _ := pPeekMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0, 1) // PM_REMOVE
		if r == 0 {
			return
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
	}
}

func hideScreen() {
	for i := 8; i >= 0; i-- {
		setAlpha(float64(i) / 8)
		pump()
		time.Sleep(30 * time.Millisecond)
	}
	pDestroyWindow.Call(screenWnd)
	screenWnd = 0
	pShowCursor.Call(1)
	if terminalWnd != 0 {
		pSetForegroundWindow.Call(terminalWnd) // hand focus back so the menu keeps working
	}
}

// ---------- session ----------

type result struct {
	auto, safety bool
	took         time.Duration
}

func runSession(m mode, simulate bool) result {
	resetSession()
	flushKeys()
	if !simulate {
		setHook(true)
	}
	write(esc + "?25l")
	showScreen(m)

	var res *result
	for res == nil {
		pump()
		now := time.Now()
		t := now.Sub(startedAt)

		mu.Lock()
		heartbeat = now
		// preview: hold the exit keys after a moment so you can see the ring
		if simulate && t > 1600*time.Millisecond && comboSince.IsZero() && releasingSince.IsZero() {
			comboSince = now
		}
		if releasingSince.IsZero() && !comboSince.IsZero() && now.Sub(comboSince) >= holdSeconds {
			releasingSince = now
		}
		fired := watchdogFired
		mu.Unlock()

		s := snapshot()
		letGo := 3 * time.Second
		if simulate {
			letGo = 600 * time.Millisecond
		}
		switch {
		case fired:
			res = &result{true, true, t}
		case !s.releasingSince.IsZero() && (len(s.down) == 0 || now.Sub(s.releasingSince) > letGo):
			res = &result{false, false, t}
		case t >= timeout:
			res = &result{true, false, t}
		}

		setAlpha(t.Seconds() / 0.4)
		// On a blank screen the hint hides after 3s so it doesn't cover dust; it comes back with the ring.
		switch {
		case !s.releasingSince.IsZero():
			updateScreen("unlocked — let go of the keys", true, 1)
		case !s.comboSince.IsZero():
			updateScreen("keep holding", true, math.Min(now.Sub(s.comboSince).Seconds()/holdSeconds.Seconds(), 1))
		default:
			updateScreen("hold  "+exitCombo.text()+"  to exit", m == modeKeyboard || t < 3*time.Second, -1)
		}
		time.Sleep(33 * time.Millisecond)
	}
	setHook(false)
	flushKeys() // drop anything that slipped through
	hideScreen()
	return *res
}

func summary(m mode, r result) string {
	parts := []string{m.title(), duration(r.took)}
	if r.safety {
		parts = append(parts, "unlocked for safety")
	} else if r.auto {
		parts = append(parts, "unlocked by itself")
	}
	return "   " + accent + "✓" + reset + " " + parts[0] + muted + "  ·  " + strings.Join(parts[1:], "  ·  ") + reset
}

// afterPrompt returns the next item to run, -2 for the menu, or -1 to quit.
func afterPrompt(current int) int {
	write("\n   " + bold + "↵" + reset + " " + faint + "again" + reset + "   " + bold + "m" + reset + " " + faint + "menu" + reset + "   " + bold + "q" + reset + " " + faint + "quit" + reset)
	flushKeys()
	for {
		k := readKey(time.Second)
		n := -3
		switch {
		case k == "\r" || k == "\n" || k == " ":
			n = current
		case k == "m" || k == "\x1b[A" || k == "\x1b[B":
			n = -2
		case k == "q" || k == "\x1b" || k == "\x03":
			n = -1
		case len(k) == 1 && k[0] >= '1' && k[0] < '1'+byte(len(items)):
			n = int(k[0] - '1')
		}
		if n != -3 {
			write("\r" + esc + "K" + esc + "1A\r" + esc + "K")
			return n
		}
	}
}

// ---------- run ----------

func main() {
	parseArgs()
	setupConsole()

	if preview {
		rawInput()
		r := runSession(modeKeyboard, true)
		write("\n" + summary(modeKeyboard, r) + "  " + faint + "(preview)" + reset + "\n\n")
		quit(0)
	}

	if startMode == modeNone && !isTerminal() {
		usage()
	}
	rawInput()

	pick, lastSel := -2, 0
	for i, it := range items {
		// `wipe configure` opens the exit-shortcut screen first, then lands on the menu
		if (configureOnly && it.mode == modeNone) || (!configureOnly && startMode != modeNone && it.mode == startMode) {
			pick = i
		}
	}
	for {
		if pick == -2 {
			if pick = runMenu(lastSel); pick == -1 {
				break
			}
		}
		idx := pick
		lastSel, pick = idx, -2

		if items[idx].mode == modeNone {
			configure()
			continue
		}
		ensureHook()
		m := items[idx].mode
		r := runSession(m, false)
		write("\n" + summary(m, r) + "\n")
		if pick = afterPrompt(idx); pick == -1 {
			break
		}
	}
	quit(0)
}
