# custom-scripts/
#
# 容器每次启动时，entrypoint 会按文件名顺序执行本目录下的 *.sh
# （以容器当前用户运行——默认 root；之后才降权运行 dsh）。
# 目录不挂载、为空、或没有 .sh 文件都不会报错。
#
# 规则：
# - 每次启动都会执行，脚本必须幂等（已装的包跳过、已存在的文件不覆盖等）
# - 某个脚本失败只记 WARN，不影响其它脚本和 dsh 启动
# - 挂载方式见 docker-compose.yml 的 custom-scripts 卷
#
# 示例脚本：
#   10-apt-packages.sh  按环境变量 EXTRA_APT_PACKAGES 补装 apt 包（编译链、CLI 工具等）
#   20-pip-packages.sh  按环境变量 PIP_PACKAGES 安装 Python 包
#
# 写自己的脚本照这个模式来：读环境变量 → 检查是否已做过 → 没做过才做。
