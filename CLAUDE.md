Based on these instructions:
https://docs.gitea.com/installation/install-from-binary

write a script for QNAP (Linux AMD64)
I have already tested that the app starts in that environment:


rls1203@NAS-RLS:~
$ wget -O gitea https://dl.gitea.com/gitea/1.25.4/gitea-1.25.4-linux-amd64
--2026-02-11 22:51:07--  https://dl.gitea.com/gitea/1.25.4/gitea-1.25.4-linux-amd64
Resolving dl.gitea.com... 3.174.141.129, 3.174.141.121, 3.174.141.57, ...
Connecting to dl.gitea.com|3.174.141.129|:443... connected.
HTTP request sent, awaiting response... 200 OK
Length: 114248256 (109M) [binary/octet-stream]
Saving to: ‘gitea’

gitea                                                100%[===================================================================================================================>] 108.96M  59.7MB/s    in 1.8s

2026-02-11 22:51:09 (59.7 MB/s) - ‘gitea’ saved [114248256/114248256]


rls1203@NAS-RLS:~
$ chmod +x gitea

rls1203@NAS-RLS:~
$ ls
all_sh.txt          backup    claudebox.run       convert_batch12.sh  crontab          fastfetch  installed.txt     markitdown    opkg.txt           scripts    to do .txt
atuin-installer.sh  build     convert_batch10.sh  convert_batch8.sh   docker_proxy.py  gitea      installpaths.txt  mcwrap        pi_command_center  stats.txt
atuin.sh            check.sh  convert_batch11.sh  convert_batch9.sh   downloads        gits       logs              medialib.txt  @Recycle           test

rls1203@NAS-RLS:~
$ ./gitea
2026/02/11 22:51:58 cmd/web.go:266:runWeb() [I] Starting Gitea on PID: 12074
2026/02/11 22:51:58 cmd/web.go:114:showWebStartupMessage() [I] Gitea version: 1.25.4 built with GNU Make 4.3, go1.25.6 : bindata, sqlite, sqlite_unlock_notify
2026/02/11 22:51:58 cmd/web.go:115:showWebStartupMessage() [I] * RunMode: prod
2026/02/11 22:51:58 cmd/web.go:116:showWebStartupMessage() [I] * AppPath: /share/homes/rls1203/gitea
2026/02/11 22:51:58 cmd/web.go:117:showWebStartupMessage() [I] * WorkPath: /share/homes/rls1203
2026/02/11 22:51:58 cmd/web.go:118:showWebStartupMessage() [I] * CustomPath: /share/homes/rls1203/custom
2026/02/11 22:51:58 cmd/web.go:119:showWebStartupMessage() [I] * ConfigFile: /share/homes/rls1203/custom/conf/app.ini
2026/02/11 22:51:58 cmd/web.go:120:showWebStartupMessage() [I] Prepare to run install page
2026/02/11 22:51:58 cmd/web.go:328:listen() [I] Listen: http://0.0.0.0:3000
2026/02/11 22:51:58 cmd/web.go:332:listen() [I] AppURL(ROOT_URL): http://localhost:3000/
2026/02/11 22:51:58 modules/graceful/server.go:50:NewServer() [I] Starting new Web server: tcp:0.0.0.0:3000 on PID: 12074
2026/02/11 22:51:58 modules/graceful/server.go:76:(*Server).ListenAndServe() [E] Unable to GetListener: listen tcp 0.0.0.0:3000: bind: address already in use
2026/02/11 22:51:58 cmd/web.go:377:listen() [E] Failed to start server: listen tcp 0.0.0.0:3000: bind: address already in use
2026/02/11 22:51:58 cmd/web.go:379:listen() [I] HTTP Listener: 0.0.0.0:3000 Closed
2026/02/11 22:51:58 cmd/web.go:152:serveInstall() [E] Unable to open listener for installer. Is Gitea already running?
2026/02/11 22:51:58 modules/graceful/manager.go:176:(*Manager).doHammerTime() [W] Setting Hammer condition
2026/02/11 22:51:59 modules/graceful/manager.go:192:(*Manager).doTerminate() [W] Terminating
2026/02/11 22:51:59 .../graceful/manager_unix.go:154:(*Manager).handleSignals() [W] PID: 12074. Background context for manager closed - context canceled - Shutting down...
2026/02/11 22:51:59 cmd/web.go:158:serveInstall() [I] PID: 12074 Gitea Web Finished
Command error: listen tcp 0.0.0.0:3000: bind: address already in use

however port 3004 worked

$ ./gitea web --port 3004
2026/02/11 23:36:25 cmd/web.go:266:runWeb() [I] Starting Gitea on PID: 21463
2026/02/11 23:36:25 cmd/web.go:114:showWebStartupMessage() [I] Gitea version: 1.25.4 built with GNU Make 4.3, go1.25.6 : bindata, sqlite, sqlite_unlock_notify
2026/02/11 23:36:25 cmd/web.go:115:showWebStartupMessage() [I] * RunMode: prod
2026/02/11 23:36:25 cmd/web.go:116:showWebStartupMessage() [I] * AppPath: /share/homes/rls1203/gitea
2026/02/11 23:36:25 cmd/web.go:117:showWebStartupMessage() [I] * WorkPath: /share/homes/rls1203
2026/02/11 23:36:25 cmd/web.go:118:showWebStartupMessage() [I] * CustomPath: /share/homes/rls1203/custom
2026/02/11 23:36:25 cmd/web.go:119:showWebStartupMessage() [I] * ConfigFile: /share/homes/rls1203/custom/conf/app.ini
2026/02/11 23:36:25 cmd/web.go:120:showWebStartupMessage() [I] Prepare to run install page
2026/02/11 23:36:26 cmd/web.go:328:listen() [I] Listen: http://0.0.0.0:3004
2026/02/11 23:36:26 cmd/web.go:332:listen() [I] AppURL(ROOT_URL): http://localhost:3004/
2026/02/11 23:36:26 modules/graceful/server.go:50:NewServer() [I] Starting new Web server: tcp:0.0.0.0:3004 on PID: 21463