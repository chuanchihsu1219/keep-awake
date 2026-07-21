' Launch the Claude keep-awake tray app fully hidden (no window, no flash).
' Portable: resolves its own folder, so it works wherever this folder is placed.
Dim fso, here
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\KeepAwakeTray.ps1""", 0, False
