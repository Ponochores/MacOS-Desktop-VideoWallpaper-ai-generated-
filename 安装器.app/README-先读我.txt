这个 .app 里没有可执行文件 —— 它需要先编译一次。

为什么不在仓库里放编译好的二进制：
  · 它是架构相关的（arm64 / x86_64 各一份），放进去对另一种架构没用
  · 二进制无法审查，来源也不透明
  · 自己编译只要几秒，仓库却要为此胖 168KB 且带一个"看不见的黑盒"

怎么编译（只需一次）：

    cd <本项目目录>
    mkdir -p "安装器.app/Contents/MacOS"
    swiftc -O -o "安装器.app/Contents/MacOS/Installer" \
      Installer/Installer.swift -framework Cocoa

编完之后就可以双击「安装器.app」来安装/更新壁纸，
以后改源码重新双击它即可（它会自己重新编译自己）。
