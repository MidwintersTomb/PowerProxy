# PowerProxy

![PowerShell logo with two circuits on the left connecting to it and two circuits exiting it on the right.  Below it is the word "PowerProxy"](https://raw.githubusercontent.com/MidwintersTomb/MediaFiles/refs/heads/main/Pictures/PowerShot.png)

## A PowerShell script using .Net functions to run a SOCKS5 proxy server

### Usage:

```powershell
  .\powerproxy.ps1 -L <port> [-V | -VV | -VVV]
```

### Options:

```
  -L <port>   Required. Port on which the proxy listens.
  -V          Display connection and disconnection states.
  -VV         Write full proxy logs to C:\Temp\proxy.log.
  -VVV        Display connection states and write full logs.
```

### Examples:

```powershell
  .\powerproxy.ps1 -L 1865
  .\powerproxy.ps1 -L 1865 -v
  .\powerproxy.ps1 -L 1865 -VV
  .\powerproxy.ps1 -L 1865 -vVv
```
## So what is this exactly?

Exactly what it says, a SOCKS5 proxy server via .ps1 file.

After putting work effort in [PowerShot](https://github.com/MidwintersTomb/PowerShot) I knew that there had to be a way to run a proxy server through PowerShell.  I took the original code that I had written pre-LLM and forked it into this project.  I spent about a week arguing with a LLM, troubleshooting, learning, arguing with a LLM more, more troubleshooting, then a lot of testing.  Overall, I'm pretty happy with how it turned out.  I've been able to proxy YouTube videos through it while also proxying remote shells through it at the same time.  Hope you all enjoy it, find it interesting, use it as a way to waste a weekend, whatever way it is you want to have fun with it.

## Advice

Be aware - if you're running this through a remote shell or similar where you don't have a full fledged console, it will hang your session, as it's open on the system waiting for `Q` to be pressed.

As usual, do with it what you will, I'm not responsible for you doing something dumb with it.
