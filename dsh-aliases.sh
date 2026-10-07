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
# PROMPT — show the real project name, not /workspace
#############################

# Mount point is always /workspace. run-dsh.sh exports WORKSPACE_NAME as the
# host folder basename (e.g. inventrip_api).
#
# UI terminal (dsh-shell): bash --rcfile /tmp/dsh-shell-*/bashrc -i which only
# sources ~/.bashrc. home-bashrc.sh is bind-mounted to /home/node/.bashrc and
# sources this file → aliases + project prompt.
#
# Agent PTY (dsh-terminal-bash): sets DSH_PTY_SESSION_ID and forces readiness
# via OSC 133 + exact tail "dsh> ". Detect that env and keep the controlled
# tail while printing project name on the previous line.
__dsh_prompt_dir() {
  if [ "$PWD" = /workspace ]; then
    printf '%s' "${WORKSPACE_NAME:-workspace}"
  elif [ "${PWD#/workspace/}" != "$PWD" ]; then
    printf '%s' "${WORKSPACE_NAME:-workspace}/${PWD#/workspace/}"
  else
    printf '%s' "${PWD/#$HOME/~}"
  fi
}

__dsh_prompt() {
  local exit_code=$?
  local dir branch
  dir=$(__dsh_prompt_dir)
  branch=$(git --no-pager symbolic-ref --short HEAD 2>/dev/null || true)

  # Only agent terminal-bash sets DSH_PTY_SESSION_ID. UI dsh-shell does not.
  if [ -n "${DSH_PTY_SESSION_ID:-}" ]; then
    # Project + branch above the controlled prompt (not in promptTail).
    printf '\033[36m%s\033[0m' "$dir"
    if [ -n "$branch" ]; then
      printf ' \033[33m(%s)\033[0m' "$branch"
    fi
    printf '\n'
    # dsh-terminal-bash readiness: OSC 133;D then exact printable "dsh> "
    printf '\033]133;D;%s\007' "$exit_code"
    PS1='dsh> '
  else
    local git_part=""
    if [ -n "$branch" ]; then
      git_part=" \[\e[33m\]($branch)\[\e[0m\]"
    fi
    PS1="\[\e[36m\]$dir\[\e[0m\]$git_part\$ "
  fi
  return $exit_code
}
PROMPT_COMMAND=__dsh_prompt

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
