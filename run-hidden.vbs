' Launch the LiteLLM gateway with no visible console window.
'
' The scheduled task calls this via wscript.exe; window style 0 = hidden.
' Without it, cmd.exe would leave a black console window sitting on the
' desktop for as long as the gateway runs -- and closing that window
' would kill the gateway.
'
' The launcher is resolved relative to this script, so the folder can be
' placed anywhere.

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run """" & scriptDir & "\start-gateway.cmd""", 0, False
