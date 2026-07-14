# if not running interactively, don't do anything
[[ $- != *i* ]] && return

export EDITOR=vi
export VISUAL=vi

export PATH="$PATH:$HOME/scripts"

export PS1='\[\e[31m\][\[\e[33m\]\u\[\e[32m\]@\[\e[34m\]\h \[\e[35m\]\W\[\e[31m\]]\[\e[m\]\$ '

alias nvim="nvi"
alias yay="ya"

alias sd="sudo dinitctl"
alias sc="run-host systemctl --user"
alias ssc="run-host-root systemctl"
alias jc="run-host journalctl --user -u"
alias jjc="run-host journalctl -u"

alias clean-cache="ya -Yc && ya -Scc && bun pm -g cache rm"
alias pa="run-host podman attach "
alias caddy-reload="run-host podman exec -w /etc/caddy caddy caddy reload"
