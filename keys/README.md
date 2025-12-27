# SSH Keys for Pi Access

Place your SSH public keys here to automatically inject them into the rootfs.

## Option 1: Single File (Recommended)

Create an `authorized_keys` file with your public key(s):

```bash
# Copy your key
cp ~/.ssh/id_ed25519.pub ./authorized_keys

# Or concatenate multiple keys
cat ~/.ssh/id_ed25519.pub >> ./authorized_keys
cat ~/.ssh/id_rsa.pub >> ./authorized_keys
```

## Option 2: Use --ssh-key Flag

Specify a key when syncing:

```bash
./scripts/sync-rootfs.sh ../openseastack/output --ssh-key ~/.ssh/mykey.pub
```

## Auto-Detection Order

If no key is specified, the script looks for:

1. `./keys/authorized_keys` (this directory)
2. `~/.ssh/id_ed25519.pub`
3. `~/.ssh/id_rsa.pub`

## After Sync

SSH into the Pi:

```bash
ssh root@<pi-ip>
# or if mDNS works:
ssh root@openseastack.local
```
