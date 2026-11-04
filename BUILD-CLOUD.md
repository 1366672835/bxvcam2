# 云端编译：不用 Mac，2 分钟拿到 BXFloat.dylib

你这台机器没有编译器也没网，所以**成品 dylib 我这边编不出来**。
但 GitHub 免费提供 macOS 编译机，你只要有个浏览器就行。

---

## 第一次准备（5 分钟）

### 1. 注册 GitHub

https://github.com/signup —— 邮箱就行，免费。

### 2. 建一个空仓库

1. 右上角 `+` → `New repository`
2. 名字随便，比如 `bxfloat`
3. 选 **Private**（别人看不到你的代码）
4. **不要**勾 "Add a README"
5. 点 `Create repository`

### 3. 上传工程

在新建好的空仓库页面，点 **`uploading an existing file`**（蓝色小字）。

把 `replica-troll` 文件夹里的**所有内容**拖进去：

```
Makefile
Tweak.xm
release.sh
README.md
TROLLSTORE.md
BXCore/          (整个文件夹)
BXModules/       (整个文件夹)
.github/         ← 这个必须传！隐藏文件夹
```

> Windows 资源管理器看不到 `.github` 文件夹。
> 在地址栏输入路径后，勾选「查看 → 显示 → 隐藏的项目」才看得到。
>
> 或者直接用命令行打包上传，见下面「命令行方式」。

拖完点绿色的 `Commit changes`。

---

## 命令行方式（更稳，推荐）

在 `replica-troll` 文件夹里开 PowerShell：

```powershell
# 1. 初始化
git init
git add .
git commit -m "init"

# 2. 连到你刚建的仓库（换成你自己的地址）
git remote add origin https://github.com/你的用户名/bxfloat.git
git branch -M main
git push -u origin main
```

> 没有 git？装一个：https://git-scm.com/download/win
> 或者用 GitHub Desktop：https://desktop.github.com/

---

## 编译

1. 打开仓库页面 → 点顶部 **`Actions`**
2. 左边选 **`build-dylib`**
3. 右边点 **`Run workflow`** → 绿色按钮
4. 等 2–4 分钟（有个黄色圆点在转）
5. 变成绿色 ✅ 后，点进这次运行记录
6. 拉到底部 **`Artifacts`** → 点 **`BXFloat-dylib`**
7. 下载得到 `BXFloat-dylib.zip`，解压里面就是 **`BXFloat.dylib`**

**这就是你要的插件文件。**

---

## 注入到游戏

拿到 `BXFloat.dylib` 后：

### 最省事：TrollFools

1. TrollStore 里装 [TrollFools](https://github.com/Lessica/TrollFools)
2. 把 `BXFloat.dylib` 传到手机（文件 App / 微信传文件 / AirDrop）
3. 打开 TrollFools → 选游戏 → 「注入」→ 选 `BXFloat.dylib`
4. 开游戏

### 或者重签 IPA

见 [TROLLSTORE.md](TROLLSTORE.md) 的 B 方案。

---

## 编译前必改一行

`BXCore/BXConfig.h` 第 9 行：

```objc
static NSString *const kBXTargetBundleID = @"com.你的.游戏";
```

不填的话**所有 App 都会弹面板**。改完再上传/再 push 一次就会重新编译。

怎么查游戏的 Bundle ID：

- 手机装个 **Filza** → 找到 `.app` 文件夹 → 看里面的 `Info.plist` 的 `CFBundleIdentifier`
- 或者电脑上用 iMazing / 爱思助手 看已安装应用的标识

---

## 排查

| 现象 | 原因 | 解决 |
|---|---|---|
| Actions 页面没有 `build-dylib` | `.github` 文件夹没上传 | 用命令行 `git add .` 重新推 |
| 编译失败 `no such file: Tweak.xm` | 传的时候多套了一层文件夹 | 仓库根目录应该直接是 `Makefile`，不能是 `replica-troll/Makefile` |
| 编译失败 `SDK not found` | SDK 下载超时 | 重新点一次 `Run workflow` |
| 下载的 zip 是空的 | `if-no-files-found: error` 会直接报错，不会给空包 | 看 Actions 日志红字 |
| 装上闪退 | dylib 没签名 | 用 TrollFools 注入（它自动签），别手动塞 |
| 装上没面板 | Bundle ID 不匹配 | 改 `BXConfig.h` 重编 |

---

## 如果你有 Mac

那就更简单，一条命令：

```bash
export THEOS=~/theos
cd replica-troll
./release.sh
# → dist/BXFloat.dylib
```
