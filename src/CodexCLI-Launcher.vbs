Option Explicit

Dim fso, shell, scriptDir, psPath, launcherPath, command

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
launcherPath = fso.BuildPath(scriptDir, "CodexCLI-Launcher.ps1")

command = """" & psPath & """" & _
    " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & _
    """" & launcherPath & """"

shell.Run command, 0, True
