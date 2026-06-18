# script

## komari-agent 

这个脚本用于把 Komari Agent 从默认 root 运行，改成低权限 komari 用户运行，并关闭 Web SSH/RCE 和自动更新，同时加上 systemd 沙箱限制，降低被控端风险。
