' UnProcessTool GUI launcher: starts the PowerShell GUI without any console window flash.
' Used by the Explorer context menu (wscript.exe LaunchGui.vbs "<path>").
Option Explicit
Dim sh, fso, dir, target, cmd
If WScript.Arguments.Count < 1 Then WScript.Quit 1
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
target = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & dir & "\UnProcessTool.ps1"" -Gui -Path """ & target & """"
Set sh = CreateObject("WScript.Shell")
sh.Run cmd, 0, False
