Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powershellExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
command = """" & powershellExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\launcher.ps1"""

shell.Run command, 0, False

