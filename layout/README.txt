这个目录会被 Theos **原样拷进 deb 的安装包**，
并且 rootless 打包时会自动加上 `/var/jb` 前缀。

为什么需要它：
Theos 只会自动安装**与 tweak 同名**的 `VCam.plist`。
`VCam-mediaserverd.plist` 名字不同，如果不放进这里，
装完 deb 之后 mediaserverd 的 filter 就缺失 ——
结果是「系统级注入完全不生效」，只剩 App 层兜底。

本工程用两种方式保证它被打进包（任一生效即可）：

1. `.github/workflows/build.yml` 里的
   「把 mediaserverd filter 放进 layout」步骤会在编译前自动拷贝；
2. 你也可以手动执行：

   mkdir -p layout/Library/MobileSubstrate/DynamicLibraries
   cp VCam-mediaserverd.plist layout/Library/MobileSubstrate/DynamicLibraries/

安装后 filter 的落地位置：

  rootful : /Library/MobileSubstrate/DynamicLibraries/VCam-mediaserverd.plist
  rootless: /var/jb/Library/MobileSubstrate/DynamicLibraries/VCam-mediaserverd.plist

自检命令（在 iPhone 上）：

  ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/VCam*
