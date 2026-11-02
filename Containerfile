# PowerBFD in a PowerShell container. Lab use only.
#
#   podman build -f Containerfile -t powerbfd .
#   podman run -it --rm --network host powerbfd
#
# Host networking lets sessions reach lab devices directly. UDP 3784/4784 are unprivileged-safe only when
# nothing else on the host (FRR, BIRD) already listens there; use -LocalAddress and -ListenPort to avoid clashes.
FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04

COPY . /usr/local/share/powershell/Modules/PowerBFD
RUN rm -rf /usr/local/share/powershell/Modules/PowerBFD/.git /usr/local/share/powershell/Modules/PowerBFD/Containerfile \
    && pwsh -NoProfile -Command "Import-Module PowerBFD; Get-Module PowerBFD | Select-Object Name, Version"

ENTRYPOINT ["pwsh", "-NoLogo", "-NoExit", "-Command", "Import-Module PowerBFD"]
