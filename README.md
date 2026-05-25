# sbox
sandbox scripts for linux and mac (arm & x64). Isolate claude from files not in folder path

```
DIR=/path/to/sbox

alias sbox='$DIR/sbox' 		# starts a sandbox in current folder
alias claude='$DIR/claude'	# starts claude inside a sandbox in current folder
```
```
paths.conf		# define which paths the sandbox can get access RO / RW
				# now:  RO paths with executable tools
				#		RW ~/.claude, ~/.cache, ~/.config
```

```
method:
	linux:	bwrap
	max:	sandbox-exec
```