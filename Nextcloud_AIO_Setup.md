# Nextcloud 33 on Azure — AIO Setup, iPhone Auto Upload & Migration Guide

> Goes with: `template-aio-arm.json` + `install-aio.sh`
> Stack: Ubuntu 24.04 ARM64 · Nextcloud All-in-One (Docker) · Azure Blob external storage

---

## 1. Before you deploy

You'll need:

1. **An SSH key pair** on your Windows box:
   ```powershell
   ssh-keygen -t ed25519 -C "nextcloud-azure"
   # default location: C:\Users\venkum\.ssh\id_ed25519(.pub)
   Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
   ```
   Copy the **single line** that starts with `ssh-ed25519 ...` — that's `sshPublicKey`.

2. **Your home IP** (so we can lock down SSH + AIO admin):
   ```powershell
   (Invoke-RestMethod https://api.ipify.org).Trim()
   ```
   Use this as `allowedSshSourceCidr` with `/32` appended (e.g. `203.0.113.4/32`).

3. **A DNS label** (becomes `<label>.<region>.cloudapp.azure.com`) — e.g. `venkum-nc`.
   This is fine to use as your public hostname; you only need a custom domain if
   you want a vanity name like `cloud.example.com`.

4. **Upload `install-aio.sh` to a public URL** that the VM's CustomScript
   extension can fetch. Options:
   - Push to your existing GitHub repo (the template currently references
     `github.com/ipraveenmv/scripts/.../install-aio.sh`). Just commit this
     file to that repo and you're done.
   - Or edit `template-aio-arm.json` → `variables.installScriptUrl` to point
     anywhere reachable (e.g. an Azure Storage blob with public read on that one file).

---

## 2. Deploy the template

### Recommended: use the PowerShell wrapper

```powershell
cd C:\Users\venkum\Nextcloud\Documents\Nextcloud_Install
.\Deploy-Nextcloud.ps1
```

The wrapper will:
- Check that Azure CLI is installed and you're logged in (and run `az login` if not)
- Generate an SSH key pair if `~/.ssh/id_ed25519` doesn't already exist
- Auto-detect your home IP and offer to lock SSH + AIO admin port to it
- Prompt for the DNS label, email, and (optionally) a custom domain
- Show a summary, ask you to confirm, then deploy
- Print the AIO admin URL, the Nextcloud URL, the SSH command, and your
  storage account key (which you'll need in §4)

You can also pass parameters non-interactively:

```powershell
.\Deploy-Nextcloud.ps1 `
    -ResourceGroup nextcloud-rg `
    -Location eastus `
    -DnsLabel venkum-nc `
    -Email you@example.com
```

### Manual alternative (raw `az` commands)

If you'd rather not use the wrapper:

```powershell
$rg     = "nextcloud-rg"
$loc    = "eastus"
$dns    = "venkum-nc"                      # becomes venkum-nc.eastus.cloudapp.azure.com
$fqdn   = "$dns.$loc.cloudapp.azure.com"   # or your custom domain
$email  = "you@example.com"
$myip   = "$((Invoke-RestMethod https://api.ipify.org).Trim())/32"
$sshkey = Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub -Raw

az group create -n $rg -l $loc

az deployment group create `
  --resource-group $rg `
  --template-file C:\Users\venkum\Nextcloud\Documents\Nextcloud_Install\template-aio-arm.json `
  --parameters `
      adminUsername=azureuser `
      sshPublicKey="$sshkey" `
      sslEmail=$email `
      dnsNameForPublicIP=$dns `
      nextcloudFqdn=$fqdn `
      allowedSshSourceCidr=$myip
```

When it finishes, the `outputs` block prints `aioAdminUrl`, `publicFqdn`, and
`sshCommand`. **The CustomScript extension takes another 5–10 minutes** after
the deployment "completes" to finish pulling Docker + AIO images. SSH in and
watch with:

```bash
sudo docker ps
sudo tail -f /var/log/azure/custom-script/handler.log
```

---

## 3. First-boot AIO configuration

1. Browse to the `aioAdminUrl` output (e.g. `https://venkum-nc.eastus.cloudapp.azure.com:8080`).
   You'll get a TLS warning — AIO uses a self-signed cert on port 8080. Accept it.
2. **Copy the master password** shown on screen. Save it in your password manager.
3. Submit your domain — same value you passed as `nextcloudFqdn`.
   AIO will verify DNS points to your VM. (If using `*.cloudapp.azure.com`, it does already.)
4. **Optional containers — recommended for your use case**:
   - ☑ **Imaginary** — fast HEIC/HEIF preview generation (essential for iPhone photos)
   - ☑ **ClamAV** — virus scan on upload
   - ☑ **Fulltextsearch** — search inside documents
   - ☑ **Collabora** — edit Office docs in-browser
   - ☑ **Talk** — video calls (light on a B2pls)
   - ☑ **Whiteboard** — collaborative drawing (skip if RAM is tight)
   - ☐ **OnlyOffice** — pick *either* Collabora *or* OnlyOffice, not both
5. Hit **"Download and start containers"**. First pull is ~3–5 GB, takes 5–10 min on a B2 VM.
6. Once green, click the link to your live Nextcloud at `https://<your-fqdn>`.
   Log in with the admin user/password AIO generated.

---

## 4. Add Azure Blob as External Storage

This is where your photos archive will live (cheap, scales to TBs).

### 4a. Grab the storage key

```powershell
az storage account keys list `
  --resource-group nextcloud-rg `
  --account-name <storageAccountName-from-output> `
  --query "[0].value" -o tsv
```

### 4b. Enable & configure in Nextcloud

1. Log into Nextcloud as admin → **Apps** → search **External storage support** → enable.
2. **Admin settings** → **External storages**.
3. Add a new mount:
   - **Folder name**: `Photos` (this is the folder users see in Files)
   - **External storage**: `Azure Blob Storage`
   - **Authentication**: `Account name and key`
   - **Account name**: `<storageAccountName-from-output>`
   - **Account key**: paste the key from 4a
   - **Container**: `photos`
   - **Available for**: pick the user(s), or leave global
4. Save. A green dot = working.

> Why not use Blob as *primary* storage? AIO doesn't officially support that and
> primary-on-blob breaks file locking semantics. Using it as External Storage
> for the Photos folder gives you all the cost benefits without the risk.

### 4c. Set a lifecycle policy to auto-tier old photos

```powershell
$rule = @"
{
  "rules": [{
    "name": "ArchiveOldPhotos",
    "enabled": true,
    "type": "Lifecycle",
    "definition": {
      "filters": { "blobTypes": ["blockBlob"], "prefixMatch": ["photos/"] },
      "actions": {
        "baseBlob": {
          "tierToCool":    { "daysAfterModificationGreaterThan": 30 },
          "tierToArchive": { "daysAfterModificationGreaterThan": 365 }
        }
      }
    }
  }]
}
"@
$rule | Out-File -Encoding ascii lifecycle.json
az storage account management-policy create `
  --account-name <storageAccountName-from-output> `
  --resource-group nextcloud-rg `
  --policy @lifecycle.json
```

This keeps recent photos on Hot, drops them to Cool after 30 days, and Archive
after a year. A 500 GB library costs ~$3/mo at Cool, ~$0.50/mo at Archive.

---

## 5. iPhone Auto Upload (the whole reason we're here)

For **each** iPhone (yours + family member's):

1. **App Store** → install **Nextcloud** (publisher: Nextcloud GmbH).
2. Open the app → **Log in** → enter `https://<your-fqdn>` → tap **Log in** →
   Safari opens, sign in with that user's Nextcloud account → **Grant access**.
3. In the app: **Settings (gear icon)** → **Auto upload from this device**.
4. Toggle on:
   - **Auto upload** ✅
   - **Auto upload photos** ✅
   - **Auto upload videos** ✅
   - **Background upload** ✅ (critical — keeps uploading when app is closed)
   - **Use WiFi only for photos / videos** ✅ (saves cell data)
   - **Original filename** ✅
   - **Subfolders by date** → "Yearly" or "Monthly"
5. **Auto upload folder** → set to `/Photos/<DeviceName>` (e.g. `/Photos/Venkum-iPhone`).
   Because `/Photos` is the Azure Blob external mount, every photo lands directly
   in your Azure Storage Account.
6. On iOS: **Settings → Nextcloud → Background App Refresh = ON**, and
   **Settings → Nextcloud → Cellular Data = ON** (only WiFi uploads will use
   data; this just lets the app sync metadata).

> Tip: first upload will be slow because it's processing the entire camera roll.
> Plug the phone in overnight on WiFi the first day.

### Make photos browsable like Google Photos

1. In Nextcloud admin → **Apps** → install **Memories** and **Recognize**.
2. Memories gives you a timeline view + map view.
3. Recognize will face-, object-, and place-tag your library overnight
   (runs as a cron job on the VM — CPU-heavy but only when idle).
4. Optionally install **Preview Generator**:
   ```bash
   sudo docker exec --user www-data -it nextcloud-aio-nextcloud \
     php occ app:install previewgenerator
   sudo docker exec --user www-data -it nextcloud-aio-nextcloud \
     php occ preview:generate-all -vvv
   ```

---

## 6. Migrating from your current Nextcloud 31

You have two reasonable paths:

### Path A — Fresh start, copy files over the network (simplest)
1. Bring up the new instance with AIO (steps above) — empty.
2. On the iPhones, **don't** re-enable auto-upload yet — let the historic
   library copy first.
3. From your old VM, push the data dir up via rclone or rsync over SSH:
   ```bash
   # On the OLD VM
   rsync -aHAX --info=progress2 /mnt/files/admin/files/ \
     azureuser@<new-fqdn>:/mnt/ncdata/nextcloud_data/admin/files/
   # Then on NEW VM, tell Nextcloud to index the new files:
   sudo docker exec --user www-data -it nextcloud-aio-nextcloud \
     php occ files:scan --all
   ```
4. Re-create your users in the new instance, then enable iPhone auto-upload.

### Path B — In-place upgrade (keep history, comments, shares)
1. **On the old VM** upgrade 31 → 32 → 33 in sequence (Nextcloud only allows
   one major jump at a time):
   ```bash
   sudo -u www-data php /var/www/html/nextcloud/updater/updater.phar
   # repeat for each major version
   ```
2. Verify PHP version on old VM is ≥ 8.3 (Nextcloud 33 requirement). If not,
   upgrade PHP first.
3. Take a full backup: `tar` the data dir + `mysqldump` the database.
4. On the new AIO VM, use the AIO web UI → **Backup and restore** → **Restore
   from backup**, pointing at the export from step 3. (See:
   <https://github.com/nextcloud/all-in-one#how-to-restore-a-backup>)

For a 2-user family setup, **Path A is almost always less work**. Comments,
share links, and tags don't survive Path A, but file content, folder structure,
and contacts/calendars do (export contacts/calendars from the old instance as
`.vcf`/`.ics` and re-import — they're tiny).

---

## 7. How to SSH into the VM (from Windows)

You generated an **OpenSSH key** (`id_ed25519` / `id_ed25519.pub`) — not a
PuTTY `.ppk` file. You have three good options for connecting; pick whichever
fits your workflow.

### Option A — Built-in Windows OpenSSH (easiest, no extra tools)

Windows 10/11 ships with the `ssh` command. From any PowerShell window:

```powershell
ssh azureuser@venkum-nc.eastus.cloudapp.azure.com
```

That's it. `ssh` automatically looks in `C:\Users\venkum\.ssh\id_ed25519` for
the matching private key. If you want to be explicit:

```powershell
ssh -i C:\Users\venkum\.ssh\id_ed25519 azureuser@venkum-nc.eastus.cloudapp.azure.com
```

To make it even shorter, create `C:\Users\venkum\.ssh\config`:

```
Host nextcloud
    HostName     venkum-nc.eastus.cloudapp.azure.com
    User         azureuser
    IdentityFile ~/.ssh/id_ed25519
```

Then you can just type `ssh nextcloud` from any terminal.

**File transfers** use the same key with `scp` or `sftp`:

```powershell
scp .\backup.tgz azureuser@venkum-nc.eastus.cloudapp.azure.com:/tmp/
```

### Option B — Keep using PuTTY (convert the key to .ppk)

PuTTY uses its own key format. Convert your OpenSSH key once with **PuTTYgen**
(installed alongside PuTTY):

1. Open **PuTTYgen** (Start menu → "PuTTY Key Generator").
2. **Conversions** menu → **Import key** → pick
   `C:\Users\venkum\.ssh\id_ed25519` (the private key, no extension).
3. Optionally set a key passphrase at the top.
4. Click **Save private key** → save as `C:\Users\venkum\.ssh\id_ed25519.ppk`.

Now in **PuTTY** itself:

1. **Session** → Host Name = `azureuser@venkum-nc.eastus.cloudapp.azure.com`, Port = 22.
2. **Connection → SSH → Auth → Credentials** → **Private key file for authentication**
   → browse to `id_ed25519.ppk`.
3. Back to **Session**, type a name in **Saved Sessions** (e.g. `nextcloud`),
   click **Save**. Next time, just double-click that entry.
4. Click **Open**.

For SCP from PuTTY, use **WinSCP** (same `.ppk` works) or `pscp.exe` from the
command line.

> Note: modern PuTTY (0.75+) can read OpenSSH keys directly via
> **Add key file** → pointing at the file without `.ppk`. Conversion isn't
> strictly required, but a `.ppk` is more compatible with WinSCP, FileZilla, etc.

### Option C — Windows Terminal / VS Code Remote-SSH (the nice life)

If you have **Windows Terminal** + **VS Code**, install the
**Remote - SSH** extension in VS Code. Then:

1. `Ctrl+Shift+P` → **Remote-SSH: Connect to Host**
2. Click **+ Add New SSH Host**, paste:
   `ssh azureuser@venkum-nc.eastus.cloudapp.azure.com`
3. Pick `C:\Users\venkum\.ssh\config` as the storage location.

You can now open a full VS Code window directly on the VM — edit `docker-compose`
files, browse logs, run `docker exec` — all with full IntelliSense. It's by far
the most pleasant way to administer a Linux VM from Windows.

### If SSH fails to connect

| Symptom | Likely cause | Fix |
|---|---|---|
| `Connection timed out` | NSG blocks your current IP | Your home IP changed. Update the NSG rule: `az network nsg rule update -g nextcloud-rg --nsg-name nextcloud-nsg -n AllowSSH --source-address-prefixes <your-new-ip>/32` |
| `Permission denied (publickey)` | Wrong key or wrong user | Confirm key path and that you're using `azureuser` (or whatever you passed as `adminUsername`) |
| `Host key verification failed` | VM was redeployed → new host key | `ssh-keygen -R venkum-nc.eastus.cloudapp.azure.com` then retry |
| Hangs on connection | Wrong port / NSG drops on 22 | `Test-NetConnection venkum-nc.eastus.cloudapp.azure.com -Port 22` |

### Finding / refreshing the public key for Azure

If you ever lose track of your public key (the one you paste into the template
or into the Azure Portal "Reset password" blade):

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
# starts with: ssh-ed25519 AAAAC3Nz...
```

If you lose the **private** key, you can't recover it — but you can use the
Azure Portal → VM → **Reset password** to install a new public key without
redeploying.

---

## 8. Day-2 operations

### Upgrade Nextcloud (it'll go 33 → 34 → ... over time)
- AIO admin UI (`:8080`) shows a green "update available" button when ready.
- Click it. AIO stops containers, snapshots its volumes (if backup configured),
  pulls new images, runs DB migrations, and restarts. No SSH needed.

### Backups
- In the AIO admin UI → **Backup and restore** → set the backup path to
  `/mnt/ncdata/backup` (already on your data disk, easy to capture in an Azure
  snapshot).
- Add an Azure VM snapshot schedule via Azure Backup (cheap; ~$2/mo for daily
  snapshots of a 30 GB OS disk + 128 GB data disk).

### Watch your bill
```powershell
az consumption usage list --start-date 2026-06-01 --end-date 2026-06-30 `
  --query "[?contains(instanceName, 'nextcloud')].{res:instanceName, cost:pretaxCost}" -o table
```

### Common gotchas
| Symptom | Fix |
|---|---|
| AIO admin page won't load | NSG rule for 8080 isn't allowing your IP. Update `allowedSshSourceCidr`. |
| Let's Encrypt cert fails | Your DNS doesn't point to the VM yet. Use the `*.cloudapp.azure.com` name first, switch to custom domain later. |
| iPhone uploads stop after a few hours | iOS killed background refresh. In iPhone Settings → Nextcloud → enable Background App Refresh + Cellular Data. |
| Photos folder empty in Files | Storage key is wrong, or the container name doesn't match. Check Admin → External storages — the row should have a green dot. |
| VM running out of RAM | Disable Whiteboard + ClamAV in AIO, or bump to `Standard_B2ps_v2` (~+$26/mo for 8 GB RAM). |

---

## 9. What changed vs. your old templates (summary)

| Area | Old templates | New templates |
|---|---|---|
| Ubuntu | 22.04 (Jammy) | **24.04 (Noble)** |
| Architecture | x86_64 (B2s) | **ARM64 (B2pls_v2)** — ~30% cheaper |
| Nextcloud install | Manual (PHP 7.2/7.4/8.2, Apache, MariaDB) | **AIO Docker** — one-button upgrades |
| Nextcloud version | 20.0.2 / 31.0.3 | **33.x** (latest stable) |
| Data storage | Blob NFS v3 as *primary* (fragile for DB) | **Standard SSD primary + Blob as external** |
| SSH auth | Password (in cleartext on cmdline!) | **SSH key only** |
| SSH exposure | Open to internet | **Restricted to your IP** |
| Public IP | Dynamic / Basic SKU | **Static / Standard SKU** |
| NSG | Defined but never attached to NIC/subnet 🐛 | **Attached to subnet** |
| API versions | 2015-06-15 (8+ years old) | **2023–2024** |
| Photo previews | None (no HEIC support) | **Imaginary + Memories + Recognize** |
| TLS | Certbot manual | **AIO handles Let's Encrypt automatically** |
| HSTS / hardening | Manual Apache edits | **Done by AIO Apache container** |
| Secrets in extension | adminPassword in plain `settings` ❌ | **`protectedSettings`** (encrypted) |

---

If anything is unclear or you hit a snag during deploy, just tell me which step
and I'll debug.
