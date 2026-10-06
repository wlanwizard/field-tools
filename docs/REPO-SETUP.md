# Repo setup and deploy keys

How the GitHub repo is set up, and how a customer laptop gets read-only access
without your personal GitHub credentials ever touching it.

- **Your Mac** pushes over SSH with your normal GitHub account (already set up through `gh`).
- **Customer laptops** pull with a **read-only deploy key**: an SSH key that unlocks
  this one repo and nothing else. You make a new one for each engagement and revoke
  it when you leave.

> Deploy keys only matter if the repo is **private**. A public repo can be pulled
> by anyone with the curl one-liners in the README, so skip section 2.

---

## 1. Create the repo (one time, on your Mac)

```bash
# confirm gh is logged in and uses SSH
gh auth status                     # expect: Git operations protocol: ssh
ssh -T git@github.com              # expect: "Hi wlanwizard! You've successfully authenticated..."

cd ~/_tools_repo
git init -b main
git add .
git update-index --chmod=+x tools/*.py tools/*.sh catalog.py templates/template.py templates/template.sh
git commit -m "Initial framework: conventions, templates, catalog"

gh repo create wlanwizard/field-tools --private \
  --description "One-shot sysadmin / network tools for customer laptops" \
  --source=. --remote=origin --push

git remote -v                      # expect: git@github.com:wlanwizard/field-tools.git
```

Optional (Settings → General on GitHub): turn off Wikis, Projects and Discussions. Nothing else is needed.

---

## 2. Read-only deploy key for a customer laptop

### Rules
- **One key per laptop, per engagement.** Never reuse one, and never keep a shared "field key".
- **Make the key on the customer laptop.** The private key never leaves that machine.
  Only the `.pub` file (which is safe to share) gets sent back to you.
- **Read-only.** Never use `--allow-write` for a key that lives on a customer laptop.
- **Give it a passphrase.** If the key gets left behind, it's useless without the passphrase.
- **Title it** `field-tools <customer> <laptop> <yyyy-mm-dd>` so you can find it to revoke.

### 2a. On the customer laptop: generate the key

**macOS / Linux**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/field-tools-ro -C "field-tools read-only <customer> $(date +%F)"
cat ~/.ssh/field-tools-ro.pub      # send this ONE line to yourself
```

**Windows** (OpenSSH client is built into Windows 10 and 11)
```powershell
ssh-keygen -t ed25519 -f $HOME\.ssh\field-tools-ro -C "field-tools read-only <customer> $(Get-Date -f yyyy-MM-dd)"
Get-Content $HOME\.ssh\field-tools-ro.pub
```

### 2b. On your Mac: register the public key on the repo

Save the line you sent yourself to a file, then:

```bash
gh repo deploy-key add ./customer.pub -R wlanwizard/field-tools \
  --title "field-tools acme laptop01 2026-10-06"     # read-only by default
gh repo deploy-key list -R wlanwizard/field-tools
```

Or in the browser: repo → Settings → Deploy keys → Add deploy key. Leave **Allow write access** unchecked.

### 2c. On the customer laptop: clone

The key is passed on the command line and saved in **the repo's own** git config.
Nothing changes in the customer's `~/.ssh/config` or global git settings, and later
`git pull`s keep using the deploy key.

**macOS / Linux**
```bash
git clone -c core.sshCommand="ssh -i ~/.ssh/field-tools-ro -o IdentitiesOnly=yes" \
  git@github.com:wlanwizard/field-tools.git
cd field-tools && git pull         # later updates
```

**Windows**
```powershell
git clone -c core.sshCommand="ssh -i ~/.ssh/field-tools-ro -o IdentitiesOnly=yes" `
  git@github.com:wlanwizard/field-tools.git
```

`IdentitiesOnly=yes` stops ssh from trying the customer's own keys first.

**First connect:** ssh asks you to trust github.com's host key. Check the fingerprint
before typing `yes`. For ed25519 it is `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`.
GitHub publishes the current list at
<https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>.

**No git on the laptop?** A deploy key only works with git over SSH. It can't download
the zip. Either install Git (only if the customer allows it) or clone on your Mac
and copy the folder over.

---

## 3. Leaving: revoke and clean up

**On the customer laptop**
```bash
# copy what you need out of output/ first
rm -rf ~/field-tools ~/.ssh/field-tools-ro ~/.ssh/field-tools-ro.pub
# optional: remove the github.com line ssh added
ssh-keygen -R github.com
```
```powershell
Remove-Item -Recurse -Force $HOME\field-tools, $HOME\.ssh\field-tools-ro, $HOME\.ssh\field-tools-ro.pub
ssh-keygen -R github.com
```

**On your Mac**: revoke the key. This step matters most, because it cuts access even if the laptop cleanup was missed.
```bash
gh repo deploy-key list -R wlanwizard/field-tools
gh repo deploy-key delete <KEY_ID> -R wlanwizard/field-tools
```

Review `gh repo deploy-key list` now and then. Any key with an old date in its title should be deleted.

---

## Notes
- A deploy key added with `gh` is tied to the gh login token. If you log out of gh
  (`gh auth logout`) or revoke the GitHub CLI app, **all deploy keys it added are
  deleted**. That's fine for temporary keys, but re-add any you still need.
- GitHub allows a given public key on **only one repo**. That's another reason for a new key each time.
- A deploy key gives read access to the **whole repo and its history**. Keep secrets
  and customer data out of the repo (see `CLAUDE.md` hard rules 3 and 4).
