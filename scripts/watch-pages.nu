#!/usr/bin/env nu
# Watch GitHub Pages custom-domain certificate provisioning.
#
#   nu watch-pages.nu                 # poll every 60s until the cert is live
#   nu watch-pages.nu --once          # one-shot check
#   nu watch-pages.nu --interval 30sec
#   nu watch-pages.nu --enforce       # enable "Enforce HTTPS" once the cert is approved
#   nu watch-pages.nu --ping          # send a test message to Discord and exit
#
# Discord notifications are sent when the state changes, if a webhook is given
# with --webhook or $env.DISCORD_WEBHOOK. Keep the URL out of the repository.

const DOMAIN = "oauth.otakutaku.xyz"
const REPO = "omutucat/oauth-branding"

def curl-code [url: string] {
    let r = (^curl -sS -o NUL -w "%{http_code}" --max-time 10 $url | complete)
    if $r.exit_code == 0 { $r.stdout } else { $"err($r.exit_code)" }
}

def dns-ips [] {
    let r = (^curl -sS --max-time 10 $"https://dns.google/resolve?name=($DOMAIN)&type=A" | complete)
    if $r.exit_code != 0 { return "none" }
    let j = ($r.stdout | from json)
    let ips = ($j | get -o Answer | default [] | each {|a| $a | get -o data }
        | where {|x| $x =~ '^\d{1,3}(\.\d{1,3}){3}$' } | sort | uniq)
    if ($ips | is-empty) { "none" } else { $ips | str join "," }
}

def pages-state [] {
    let r = (^gh api $"repos/($REPO)/pages" | complete)
    if $r.exit_code != 0 { return { cert: "api-error", enforced: false } }
    let j = ($r.stdout | from json)
    {
        cert: ($j | get -o https_certificate.state | default "none")
        enforced: ($j | get -o https_enforced | default false)
    }
}

def notify [url: string, msg: string] {
    if ($url | is-empty) { return }
    try {
        http post $url ({ content: $msg } | to json) --content-type application/json | ignore
    } catch {|e|
        print $"(ansi red)discord notify failed: ($e.msg)(ansi reset)"
    }
}

def main [
    --interval: duration = 60sec   # poll interval
    --once                         # check once and exit
    --enforce                      # turn on "Enforce HTTPS" when the cert is approved
    --webhook: string = ""         # Discord webhook URL (or set $env.DISCORD_WEBHOOK)
    --ping                         # send a test message and exit
] {
    let hook = (if ($webhook | is-empty) { $env | get -o DISCORD_WEBHOOK | default "" } else { $webhook })

    if $ping {
        if ($hook | is-empty) {
            error make { msg: "no webhook: pass --webhook or set $env.DISCORD_WEBHOOK" }
        }
        notify $hook "watch-pages: test message"
        print "sent"
        return
    }

    mut last = ""
    mut first = true
    loop {
        let p = (pages-state)
        let line = $"dns=(dns-ips) http=(curl-code $"http://($DOMAIN)/") https=(curl-code $"https://($DOMAIN)/") cert=($p.cert) enforced=($p.enforced)"
        let ts = (date now | format date "%H:%M:%S")
        if $line != $last {
            print $"(ansi green_bold)($ts)(ansi reset) ($line)"
            if not $first {
                notify $hook $"($ts) ($line)"
            }
            $last = $line
        } else {
            print $"(ansi dark_gray)($ts) no change(ansi reset)"
        }
        $first = false

        if $line =~ 'https=200' and $p.cert == "approved" {
            let done = $"certificate is live: https://($DOMAIN)/"
            print $"(ansi green_bold)($done)(ansi reset)"
            notify $hook $done
            if $enforce and not $p.enforced {
                ^gh api -X PUT $"repos/($REPO)/pages" -F https_enforced=true | ignore
                print "https enforced"
                notify $hook "https enforced"
            }
            break
        }
        if $once { break }
        sleep $interval
    }
}
