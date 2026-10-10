#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn
;@Ahk2Exe-SetName SymbolKey
;@Ahk2Exe-SetDescription Korean name to math symbol converter
;@Ahk2Exe-SetVersion 0.3.1
;@Ahk2Exe-SetCopyright Pimpypumpkin
; ============================================================
;  SymbolKey - 한글 이름을 수학/그리스 기호로 바꿔 주는 전역 입력기
;
;  "뮤" 치고 스페이스  →  "μ "
;  "오메가" 치고 엔터  →  "ω" + 엔터
;
;  동작 원리
;   - 한글 IME는 "뮤"를 칠 때 실제로는 a, b 키를 누른다.
;   - 이 스크립트는 눌린 키를 그대로 기록해 두었다가, 스페이스/엔터/문장부호를
;     누르는 순간 직전 키열이 symbols.ahk의 이름과 일치하면 그 글자를 지우고
;     기호를 대신 넣는다.
;   - 한/영 상태를 확인해서 영문 모드에서 "ab "를 쳤을 때는 바꾸지 않는다.
; ============================================================

; ---------------- 설정 ----------------
CheckImeMode := true      ; 한글 모드일 때만 변환 (앱에 따라 상태 확인이 안 되면 트레이에서 끄기)
CommitDelay  := 40        ; IME 조합 확정 후 기다리는 시간(ms). 느린 앱에서 글자가 덜 지워지면 올리기
ToggleHotkey := "^!k"     ; Ctrl+Alt+K : 켜기/끄기
BufferLimit  := 64        ; 기억해 두는 최근 키 입력 수

; 변환을 일으키는 키 → 실제로 입력될 문자
; 문장부호는 가상키 코드로 지정한다 ("$=" 같은 문자 이름은 일부 키에 묶이지 않는다)
EndKeys := Map(
    "Space", " ",  "Enter", "`n",  "NumpadEnter", "`n",  "Tab", "`t",
    "vkBC", ",",  "vkBE", ".",  "vkBF", "/",  "vkBA", ";",  "vkBD", "-",  "vkBB", "=",
    "vkDB", "[",  "vkDD", "]",  "vkDE", "'",
    "+0", ")",  "+9", "(",  "+8", "*",  "+vkBB", "+",  "+vkBA", ":",  "+vkBF", "?",  "+1", "!",
    "NumpadAdd", "+",  "NumpadSub", "-",  "NumpadMult", "*",  "NumpadDiv", "/",
)

SymbolsFile := A_ScriptDir "\symbols.txt"   ; 변환표: "이름=기호" 한 줄씩
StartupLnk  := A_Startup "\SymbolKey.lnk"

; ---------------- 변환표 파일 읽기 ----------------
LoadSymbols() {
    if A_IsCompiled
        FileInstall "symbols.txt", SymbolsFile, 0   ; exe에 내장된 기본 변환표를 파일이 없을 때만 꺼냄
    if !FileExist(SymbolsFile) {
        MsgBox("변환표 파일이 없습니다:`n" SymbolsFile, "SymbolKey", "Iconx")
        ExitApp
    }
    m := Map()   ; name → {symbol, ambiguous}
    for line in StrSplit(FileRead(SymbolsFile, "UTF-8"), "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "#")
            continue
        pos := InStr(line, "=")
        if !pos
            continue
        name := Trim(SubStr(line, 1, pos - 1)), symbol := Trim(SubStr(line, pos + 1))
        ambiguous := SubStr(name, 1, 1) = "?"      ; "?각=∠" : 일상어와 겹치는 이름 → 수식 문맥에서만 변환
        if ambiguous
            name := Trim(SubStr(name, 2))
        if (name != "" && symbol != "")
            m[name] := {symbol: symbol, ambiguous: ambiguous}
    }
    return m
}

; ---------------- 두벌식 자판: 자모 → 키 ----------------
CHO  := ["r","R","s","e","E","f","a","q","Q","t","T","d","w","W","c","z","x","v","g"]
JUNG := ["k","o","i","O","j","p","u","P","h","hk","ho","hl","y","n","nj","np","nl","b","m","ml","l"]
JONG := ["","r","R","rt","s","sw","sg","e","f","fr","fa","fq","ft","fx","fv","fg","a","q","qt","t","T","d","w","c","z","x","v","g"]

HangulToKeys(word) {
    keys := ""
    for ch in StrSplit(word) {
        code := Ord(ch)
        if (code < 0xAC00 || code > 0xD7A3)
            throw ValueError("한글 음절이 아닌 글자 '" ch "'")
        code -= 0xAC00
        keys .= CHO[code // 588 + 1] . JUNG[Mod(code, 588) // 28 + 1] . JONG[Mod(code, 28) + 1]
    }
    return keys
}

; ---------------- 변환표 구성 ----------------
Entries := []   ; {keys, name, symbol, len}  긴 키열부터

BuildTable() {
    global Entries := []
    bad := ""
    for name, def in LoadSymbols() {
        try {
            e := {keys: HangulToKeys(name), name: name, symbol: def.symbol, len: StrLen(name), ambiguous: def.ambiguous}
            ; 긴 키열이 먼저 오도록 삽입
            i := 1
            while (i <= Entries.Length && StrLen(Entries[i].keys) >= StrLen(e.keys))
                i++
            Entries.InsertAt(i, e)
        } catch as err
            bad .= "  " name " : " err.Message "`n"
    }
    if bad
        MsgBox("symbols.txt에서 건너뛴 항목:`n" bad, "SymbolKey", "Icon!")
}

; ---------------- 최근 입력 기록 ----------------
Buf := ""
LastHwnd := 0
LastMatch := ""
Enabled := true
UndoAvail := false   ; 직전 변환을 백스페이스로 되돌릴 수 있는 상태
LastUndo := ""       ; {n: 지울 글자 수, text: 되살릴 원문}

ResetBuf(*) {
    global Buf := "", UndoAvail := false
}

OnCharTyped(ih, ch) {
    global Buf, LastHwnd, UndoAvail := false
    hwnd := WinExist("A")
    if (hwnd != LastHwnd) {
        Buf := ""
        LastHwnd := hwnd
    }
    ; "각3", "각 30"처럼 모호한 이름 뒤에 숫자가 오면 각도로 보고 소급 변환
    if (Enabled && IsDigit(ch) && (m := FindAmbiguousBefore(Buf)) && (!CheckImeMode || IsHangulMode())) {
        ConvertBeforeDigit(m, ch)
        return
    }
    Buf .= ch
    if (StrLen(Buf) > BufferLimit)
        Buf := SubStr(Buf, -BufferLimit)
}

OnKeyTyped(ih, vk, sc) {
    global Buf, UndoAvail := false
    if (vk = 0x08)              ; Backspace: 조합 중엔 자모 하나 = 키 하나
        Buf := SubStr(Buf, 1, -1)
    else                        ; 방향키 등 커서 이동
        Buf := ""
}

StartInputHook() {
    ih := InputHook("V I1")    ; V: 키를 가로채지 않음, I1: 이 스크립트가 보낸 키는 무시
    ih.KeyOpt("{Backspace}{Delete}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Esc}", "N")
    ih.OnChar := OnCharTyped
    ih.OnKeyDown := OnKeyTyped
    ih.OnEnd := (*) => StartInputHook()   ; 길이 제한에 닿으면 다시 시작
    ih.Start()
}

; ---------------- 한/영 상태 ----------------
IsHangulMode() {
    DetectHiddenWindows true
    hwnd := 0
    try hwnd := ControlGetFocus("A")
    if !hwnd
        hwnd := WinExist("A")
    imeWnd := DllCall("imm32\ImmGetDefaultIMEWnd", "Ptr", hwnd, "Ptr")
    if !imeWnd
        return true     ; IME 창을 못 찾는 앱은 확인 불가 → 변환 허용
    try {
        ; WM_IME_CONTROL: 한국어 IME는 영문 모드에서도 open=1일 수 있어 conversion mode의 한글 비트까지 본다
        open := SendMessage(0x283, 0x005, 0, , "ahk_id " imeWnd, , , , 200)   ; IMC_GETOPENSTATUS
        conv := SendMessage(0x283, 0x001, 0, , "ahk_id " imeWnd, , , , 200)   ; IMC_GETCONVERSIONMODE
        return open && (conv & 1)                                               ; IME_CMODE_NATIVE
    }
    return true
}

; ---------------- 일치 판정 / 치환 ----------------
; hk: 눌린 끝키의 핫키 이름("$Space" 등). HotIf 콜백으로 호출된다.
CanReplace(hk := "") {
    global LastMatch := ""
    if (!Enabled || Buf = "")
        return false
    endText := EndKeys.Has(SubStr(hk, 2)) ? EndKeys[SubStr(hk, 2)] : ""
    bufLen := StrLen(Buf)
    for e in Entries {
        L := StrLen(e.keys)
        if (bufLen < L || SubStr(Buf, -L) !== e.keys)
            continue
        prev := bufLen > L ? SubStr(Buf, -(L + 1), 1) : ""
        if (prev != "" && IsAlpha(prev))     ; "뮤지컬"처럼 다른 글자에 붙어 있으면 제외 (숫자는 허용: 2뮤 → 2μ)
            continue
        if (e.ambiguous && !IsMathContext(bufLen - L, endText))   ; "각 항목"은 두고 "2각", "각)"만 변환
            continue
        if (CheckImeMode && !IsHangulMode())
            return false
        LastMatch := e
        return true
    }
    return false
}

; 이름 앞(공백 건너뜀)이 숫자·연산자·여는 괄호이거나, 끝키가 수식 기호이면 수식 문맥으로 본다
IsMathContext(prefixLen, endText) {
    static before := "0123456789+-*/=^_(<[{|"
    static after := ")*+=/^-]"
    if (endText != "" && InStr(after, endText))
        return true
    i := prefixLen
    while (i >= 1 && SubStr(Buf, i, 1) = " ")
        i--
    return i >= 1 && InStr(before, SubStr(Buf, i, 1))
}

; s가 "모호한 이름(+ 공백 하나)"으로 끝나면 {e, gap}을, 아니면 ""을 돌려준다
FindAmbiguousBefore(s) {
    gap := SubStr(s, -1) = " " ? " " : ""
    body := gap != "" ? SubStr(s, 1, -1) : s
    bodyLen := StrLen(body)
    for e in Entries {
        if !e.ambiguous
            continue
        L := StrLen(e.keys)
        if (bodyLen < L || SubStr(body, -L) !== e.keys)
            continue
        prev := bodyLen > L ? SubStr(body, -(L + 1), 1) : ""
        if (prev != "" && IsAlpha(prev))
            continue
        return {e: e, gap: gap}
    }
    return ""
}

; 숫자 ch가 막 입력된 시점: 앞의 "각(+공백)"을 지우고 "∠(+공백)숫자"로 바꾼다
ConvertBeforeDigit(m, ch) {
    global Buf, UndoAvail, LastUndo
    e := m.e
    Sleep CommitDelay                                   ; 숫자 입력으로 조합이 확정될 시간
    Send "{BS " (e.len + StrLen(m.gap) + 1) "}"
    SendText e.symbol m.gap ch
    Buf := m.gap ch
    LastUndo := {n: StrLen(e.symbol) + StrLen(m.gap) + 1, text: e.name m.gap ch}
    UndoAvail := true
}

DoReplace(endText) {
    global Buf, UndoAvail, LastUndo
    e := LastMatch
    n := e.len + 1, sym := e.symbol, orig := e.name
    ; "각 파이"처럼 바로 앞에 '모호한 이름 + 공백'이 있으면 그것도 함께 기호로 (각 → ∠)
    pre := FindAmbiguousBefore(SubStr(Buf, 1, StrLen(Buf) - StrLen(e.keys)))
    if (pre && pre.gap = " ") {
        n += pre.e.len + 1
        sym := pre.e.symbol " " sym
        orig := pre.e.name " " orig
    }
    Buf := ""
    Send "{Space}"                 ; 조합 중인 한글을 확정 (스페이스 하나가 같이 들어감)
    Sleep CommitDelay
    Send "{BS " n "}"              ; 스페이스 + 한글 음절 수만큼 지우기
    SendText sym
    switch endText {
        case " ":  Send "{Space}"
        case "`n": Send "{Enter}"
        case "`t": Send "{Tab}"
        default:   SendText endText
    }
    ; 엔터(전송)·탭(포커스 이동) 뒤에는 되돌릴 수 없다
    UndoAvail := endText != "`n" && endText != "`t"
    LastUndo := {n: StrLen(sym) + 1, text: orig endText}
}

; 변환 직후 백스페이스: 기호와 끝문자를 지우고 원래 친 한글을 되살린다
DoUndo(*) {
    global UndoAvail := false, Buf := ""
    Send "{BS " LastUndo.n "}"
    SendText LastUndo.text
}

MakeHandler(text) => (*) => DoReplace(text)

; ---------------- 켜기/끄기, 트레이 ----------------
ToggleEnabled(*) {
    global Enabled := !Enabled
    A_TrayMenu.ToggleCheck("켜기 / 끄기`t" ToggleHotkey)
    TrayTip(Enabled ? "변환 켜짐" : "변환 꺼짐", "SymbolKey")
}

ToggleImeCheck(*) {
    global CheckImeMode := !CheckImeMode
    A_TrayMenu.ToggleCheck("한글 모드일 때만 변환")
}

IsStartupEnabled() => FileExist(StartupLnk) != ""

ToggleStartup(*) {
    if IsStartupEnabled()
        FileDelete StartupLnk
    else
        FileCreateShortcut A_ScriptFullPath, StartupLnk, A_ScriptDir, , "SymbolKey"
    A_TrayMenu.ToggleCheck("로그인 시 자동 실행")
    TrayTip(IsStartupEnabled() ? "로그인할 때 자동으로 시작됩니다" : "자동 실행을 해제했습니다", "SymbolKey")
}

ShowTable(*) {
    txt := ""
    for e in Entries
        txt .= e.name " → " e.symbol (e.ambiguous ? "   (수식 문맥에서만)" : "") "`n"
    MsgBox(txt, "SymbolKey 변환표 (" Entries.Length "개)")
}

SetupTray() {
    A_IconTip := "SymbolKey"
    A_TrayMenu.Delete()
    A_TrayMenu.Add("켜기 / 끄기`t" ToggleHotkey, ToggleEnabled)
    A_TrayMenu.Add("한글 모드일 때만 변환", ToggleImeCheck)
    A_TrayMenu.Add("로그인 시 자동 실행", ToggleStartup)
    A_TrayMenu.Add()
    A_TrayMenu.Add("변환표 보기", ShowTable)
    A_TrayMenu.Add("변환표 편집 (symbols.txt)", (*) => Run('notepad.exe "' SymbolsFile '"'))
    A_TrayMenu.Add("다시 불러오기", (*) => Reload())
    A_TrayMenu.Add()
    A_TrayMenu.Add("종료", (*) => ExitApp())
    A_TrayMenu.Check("켜기 / 끄기`t" ToggleHotkey)
    if CheckImeMode
        A_TrayMenu.Check("한글 모드일 때만 변환")
    if IsStartupEnabled()
        A_TrayMenu.Check("로그인 시 자동 실행")
}

; ---------------- 시작 ----------------
BuildTable()
StartInputHook()

HotIf CanReplace
for key, text in EndKeys
    Hotkey("$" key, MakeHandler(text))
HotIf (*) => UndoAvail
Hotkey("$BackSpace", DoUndo)
HotIf

Hotkey(ToggleHotkey, ToggleEnabled)
Hotkey("~LButton", ResetBuf)
Hotkey("~RButton", ResetBuf)
Hotkey("~MButton", ResetBuf)

SetupTray()
TrayTip("변환 " Entries.Length "개 준비됨. 예: 뮤 + 스페이스 → μ", "SymbolKey 실행 중")
