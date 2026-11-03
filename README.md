Scripts for setting up a reverse engineering system on Windows.

## Requirements
- Needs powershell 7.4 or higher.
- Powershell session running with administrative privileges.

## Instructions
- Set execution policy before running to `Set-ExecutionPolicy Unrestricted -Scope CurrentUser -Force`.
- For testing or working samples, disable Windows defender, Windows update and firewall ideally through group policy.
- Depending where the samples are being run, it maybe necessary to add exceptions for windows defender with `Add-MpPreference -ExclusionPath "<FOLDER PATH>"`(a default exclusion is added for `C:\WRAP` automatically).
- There is an unattended mode which can be run with `-unattended` flag. Be sure to provide a -category or -install flag with program names.
- While this is written with Windows 11 in mind, it should also work with windows 10 as as long required components are installed.

## Thanks
Thanks to [arkbtw](https://github.com/arkbtw) for helping with winget related technicalities.