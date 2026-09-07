# DSH container terminal aliases.
# Sourced by /etc/profile -> /etc/profile.d/*.sh for bash login shells (the
# dsh-better-sidebar terminal spawns `bash -l`). NOT sourced by dsh's bash
# tool (which runs non-login `bash -c`), so these only apply to the
# interactive terminal tab — exactly where they are wanted.
#
# Adapted from the host ~/.zsh_aliases. Excluded: secrets (DB passwords, API
# tokens), destructive ops (drop/restore database, kill -9), host-only paths
# (~/Development/...), macOS-only tools (brew, defaults, open, Finder), and
# commands whose binaries are absent from this image (eza, gh, python3, docker,
# json-server, mogrify, redis-cli, kubectl, gcloud).

#############################
# GIT
#############################

alias gche='git checkout'
alias gs='git --no-pager status'
alias ga='git add'
alias gpush='git push'
alias gc='git commit -m'
alias gl='git log -n 10'
alias gm='git merge --no-edit'

#############################
# SHELL COMMANDS
#############################

alias cp='cp -i -p'   # preserves mode, ownership, timestamp; confirm overwrite
alias ..='cd ..'
alias ...='cd ../../'
alias ....='cd ../../../'
alias nr='npm run'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
alias h='history 100'
alias c='clear'
alias numFolders='find . -type d -maxdepth 1 -mindepth 1 | wc -l'
alias less='less -R'
alias bat='bat -p'   # plain output (no decorations); use `bat --paging=never` to disable the pager

#############################
# RIPGREP — fast file/content search (replaces find + grep)
#############################

# rg is already installed; these wrappers cover common "find" use cases.
# All accept an optional second arg for the search path (defaults to .).

# list all files (like `find . -type f`)
rgfiles() { rg --files "${2:-.}"; }

# find files by name pattern, case-insensitive (like `find . -iname '*pattern*'`)
rgname() { rg --files "${2:-.}" | rg -i "$1"; }

# find files by extension (like `find . -name '*.py'`)
rgext() { rg --files -g "*.${1}" "${2:-.}"; }

# find files containing text (like `grep -rl 'pattern' .`)
rgcontains() { rg -l "$1" "${2:-.}"; }

# count matches per file (like `grep -rc 'pattern' .`)
rgcount() { rg -c "$1" "${2:-.}"; }

# find files matching a regex (relative paths) — legacy, kept for host parity
find_files_regex() {
  find . -type f | grep -E "$1"
}

#############################
# SHELL SAFETY NETS — -i confirms before clobbering
#############################

alias rm='rm -i'
alias mv='mv -i'
alias ln='ln -i'

#############################
# PING
#############################

alias ping='ping -c 5'

#############################
# SYSTEM INFO
#############################

# top processes eating memory / cpu
alias psmem='ps aux | sort -nr -k 4'
alias psmem10='ps aux | sort -nr -k 4 | head -10'
alias pscpu='ps aux | sort -nr -k 3'
alias pscpu10='ps aux | sort -nr -k 3 | head -10'
