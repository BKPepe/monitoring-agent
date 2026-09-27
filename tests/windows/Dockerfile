# PowerShell 7 with PSScriptAnalyzer, for tests/run_windows_e2e.sh. The base
# is picked by the host architecture there (the Ubuntu image is amd64 only).
ARG BASE=mcr.microsoft.com/powershell:7.4-ubuntu-22.04
FROM ${BASE}
# Pinned: a new analyzer release can add findings and turn CI red on its own.
RUN pwsh -NoProfile -Command "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope AllUsers -Force"
