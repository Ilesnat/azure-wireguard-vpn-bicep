# Personal WireGuard VPN on Azure

This template creates a small Ubuntu 22.04 LTS VM that provides a personal WireGuard VPN for a phone, laptop, and tablet. Client internet traffic exits through the VM's static Azure public IPv4 address.

The design is intentionally minimal: one VM, one managed OS disk, one public IP, one NIC, one virtual network, and one network security group. There is no Bastion, load balancer, or Azure VPN Gateway.

## What you need

- An Azure subscription.
- Azure CLI, signed in with `az login`.
- The three files in this folder: `main.bicep`, `cloud-init.yaml`, and `README.md`.
- An SSH key. The commands below create one if it does not exist.
- The official WireGuard app on each device.

Run the commands from the folder containing `main.bicep` and `cloud-init.yaml`. Bicep loads the cloud-init file from that folder.

## Deploy from Windows PowerShell

Open PowerShell, change to this folder, and run:

```powershell
az login

$ResourceGroup = 'rg-personal-wireguard'
$Location = 'eastus'
$DeploymentName = 'wireguard'
$AdminUsername = 'azureuser'
$SshKeyPath = "$HOME\.ssh\id_ed25519"

if (-not (Test-Path "$SshKeyPath.pub")) {
    ssh-keygen -t ed25519 -f $SshKeyPath -N '""'
}

$AdminPublicKey = (Get-Content "$SshKeyPath.pub" -Raw).Trim()
$AdminSourceIp = (Invoke-RestMethod 'https://api.ipify.org').Trim()

Write-Host "SSH will be restricted to $AdminSourceIp/32"

az group create `
  --name $ResourceGroup `
  --location $Location

az deployment group create `
  --resource-group $ResourceGroup `
  --name $DeploymentName `
  --template-file .\main.bicep `
  --parameters `
    adminUsername=$AdminUsername `
    adminPublicKey="$AdminPublicKey" `
    adminSourceIp=$AdminSourceIp
```

Capture the deployment outputs:

```powershell
$Outputs = az deployment group show `
  --resource-group $ResourceGroup `
  --name $DeploymentName `
  --query properties.outputs `
  --output json | ConvertFrom-Json

$PublicIp = $Outputs.publicIpAddress.value
$SshCommand = $Outputs.sshCommand.value

Write-Host "Public IP: $PublicIp"
Write-Host "Connect with: $SshCommand"
```

The template accepts either a bare administrator IP or an address ending in `/32`. It always creates the SSH rule as a single-host `/32`. WireGuard UDP port 51820 remains available from the internet so your devices can connect while traveling.

## Deploy from Bash, macOS, or WSL

```bash
az login

RESOURCE_GROUP=rg-personal-wireguard
LOCATION=eastus
DEPLOYMENT_NAME=wireguard
ADMIN_USERNAME=azureuser
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

if [ ! -f "${SSH_KEY_PATH}.pub" ]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N ''
fi

ADMIN_PUBLIC_KEY="$(cat "${SSH_KEY_PATH}.pub")"
ADMIN_SOURCE_IP="$(curl -4fsS https://api.ipify.org)"

echo "SSH will be restricted to ${ADMIN_SOURCE_IP}/32"

az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION"

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --template-file main.bicep \
  --parameters \
    adminUsername="$ADMIN_USERNAME" \
    adminPublicKey="$ADMIN_PUBLIC_KEY" \
    adminSourceIp="$ADMIN_SOURCE_IP"

PUBLIC_IP="$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs.publicIpAddress.value \
  --output tsv)"

echo "Public IP: $PUBLIC_IP"
echo "Connect with: ssh ${ADMIN_USERNAME}@${PUBLIC_IP}"
```

## Finish setup and import the clients

Connect to the VM using the deployment output:

```powershell
ssh "$AdminUsername@$PublicIp"
```

Or from Bash:

```bash
ssh "${ADMIN_USERNAME}@${PUBLIC_IP}"
```

Wait for setup to finish:

```bash
sudo cloud-init status --wait
```

The expected final status is `status: done`. Client credentials are root-readable under `/root/clients/` and are deliberately **not** printed to cloud-init logs.

### Phone or tablet: scan a QR code

On the VM:

```bash
sudo wg-show-client phone
```

Open the WireGuard app, add a tunnel from a QR code, and scan the terminal. Use `tablet` instead of `phone` for the tablet configuration.

If the terminal QR code is difficult to scan, export its PNG:

```bash
sudo wg-export-client phone
exit
```

Then copy it from your computer.

PowerShell:

```powershell
scp "${AdminUsername}@${PublicIp}:phone.png" .
ssh "$AdminUsername@$PublicIp" 'rm -f ~/phone.png ~/phone.conf'
```

Bash:

```bash
scp "${ADMIN_USERNAME}@${PUBLIC_IP}:phone.png" .
ssh "${ADMIN_USERNAME}@${PUBLIC_IP}" 'rm -f ~/phone.png ~/phone.conf'
```

### Laptop: import the configuration file

On the VM:

```bash
sudo wg-export-client laptop
exit
```

PowerShell:

```powershell
scp "${AdminUsername}@${PublicIp}:laptop.conf" .
ssh "$AdminUsername@$PublicIp" 'rm -f ~/laptop.conf ~/laptop.png'
```

Bash:

```bash
scp "${ADMIN_USERNAME}@${PUBLIC_IP}:laptop.conf" .
ssh "${ADMIN_USERNAME}@${PUBLIC_IP}" 'rm -f ~/laptop.conf ~/laptop.png'
```

In the WireGuard desktop app, choose **Add Tunnel** or **Import tunnel(s) from file**, then select `laptop.conf`. Delete the local configuration file after importing it successfully.

Each client has a different private key. Do not import one client's configuration onto multiple devices.

## Confirm that the VPN works

Activate the tunnel on a client, then visit:

```text
https://api.ipify.org
```

The displayed address should match the `publicIpAddress` deployment output, not your home or mobile internet address.

On the VM, confirm that the client has connected:

```bash
sudo wg show
```

For an active client, expect a recent `latest handshake` and increasing transfer counters.

The generated client configurations route both `0.0.0.0/0` and `::/0` into WireGuard. Azure egress in this template is IPv4-only, so IPv6 is intentionally captured and blocked rather than leaking outside the VPN. Dual-stack applications normally fall back to IPv4.

## If your home public IP changes

Only SSH access is affected. Existing WireGuard clients continue working because UDP 51820 is not restricted to your home address.

Find your new address in PowerShell:

```powershell
$AdminSourceIp = (Invoke-RestMethod 'https://api.ipify.org').Trim()
```

Update only the SSH rule:

```powershell
az network nsg rule update `
  --resource-group $ResourceGroup `
  --nsg-name wg-vpn-nsg `
  --name Allow-SSH-From-Admin `
  --source-address-prefixes "$AdminSourceIp/32"
```

For a customized `vmName`, the NSG name is `<vmName>-nsg`.

## Add another device

Choose a short name and the next unused address from `10.66.66.5` through `10.66.66.254`:

```bash
sudo wg-add-client other-device 10.66.66.5
sudo wg-show-client other-device
```

Use `sudo wg-export-client other-device` if the device needs a configuration file instead of a QR code.

## Remove a lost or retired device

Revocation is immediate and persistent:

```bash
sudo wg-remove-client phone
```

The helper removes the live WireGuard peer, its persistent server configuration, and the stored client configuration and QR code.

## Troubleshooting

### Cloud-init reports an error

Inspect the status and recent log output:

```bash
sudo cloud-init status --long
sudo tail -n 100 /var/log/cloud-init-output.log
sudo journalctl -u cloud-final --no-pager -n 100
```

If package installation failed temporarily, retry safely:

```bash
sudo apt-get update
sudo apt-get install -y wireguard qrencode curl
sudo /usr/local/sbin/configure-wireguard.sh
```

The setup script preserves a complete existing configuration and restarts WireGuard. It regenerates keys only when it finds an incomplete first-time setup.

### The tunnel handshakes but websites do not load

First confirm forwarding and NAT:

```bash
sudo sysctl net.ipv4.ip_forward
sudo wg show
sudo iptables -t nat -S POSTROUTING
```

If the problem occurs only on a particular mobile or ISP network, add this line under `[Interface]` in that client's configuration and re-import it:

```ini
MTU = 1380
```

### SSH no longer connects

Your public IP may have changed. Update the NSG rule using the instructions above. You can run that Azure CLI command without SSH access to the VM.

## Security assumptions

- SSH password authentication is disabled.
- SSH is permitted only from the administrator's current public IPv4 address.
- WireGuard is the only other allowed inbound service.
- Client private keys remain in `/root/clients/` with mode `0600` unless explicitly exported.
- The VM is a single-instance personal service without redundancy.
- The setup is an IPv4 internet gateway; IPv6 is captured by client routes to prevent leakage but is not forwarded.
- The Ubuntu 22.04 Azure image is expected to name its primary interface `eth0`. Setup stops with a clear error if it does not.

## Approximate cost

As of October 2, 2026, example East US pay-as-you-go pricing is:

- Linux `Standard_B1s`: approximately **$0.0104/hour**, or **$7.59/month** at 730 hours.
- Standard static public IPv4: approximately **$0.005/hour**, or **$3.65/month**.
- A small Standard HDD managed OS disk: typically around **$1-$2/month**, depending on region and disk billing tier.

Expect approximately **$13/month** before taxes and chargeable internet data transfer. Pricing and free data-transfer allowances vary over time and by billing agreement, so check the Azure Pricing Calculator for your subscription and region.

Stopping and deallocating the VM stops compute charges, but the disk and public IP continue to cost money. To remove everything:

PowerShell:

```powershell
az group delete --name $ResourceGroup --yes --no-wait
```

Bash:

```bash
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

Also delete the tunnel from each WireGuard client app. Confirm in the Azure portal that the resource group has been deleted before assuming billing has stopped.
