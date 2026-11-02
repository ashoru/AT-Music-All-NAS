# GitHub 自动构建未签名 IPA

## 目标

每次把 `main` 分支推送到 GitHub 后，GitHub Actions 自动：

1. 从 `project.yml` 读取当前 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`。
2. 使用 XcodeGen 重新生成工程。
3. 用 `CODE_SIGNING_ALLOWED=NO` 构建 Release 版 `ATMusic.app`。
4. 打包为 `AT-Music-<版本>-build<Build>-unsigned.ipa`。
5. 上传到 Actions Artifact。
6. 自动创建/更新对应的 GitHub Release。

CI **不会自动修改版本号**。版本号以当前源码中的 `project.yml` 为准，避免“本地是 build35，GitHub 却自己变成 build36”的问题。

## 日常发布

首次绑定 GitHub 仓库后，以后只需在项目根目录运行：

```bash
./publish_to_github.sh
```

如果要改远端仓库：

```bash
./publish_to_github.sh https://github.com/<你的账号>/AT-Music.git
```

脚本会自动执行 `git add`、提交和 `git push`。push 完成后，GitHub Actions 会自动开始打包。

## GitHub 页面

- Actions：查看实时构建日志和 Artifact。
- Releases：下载最终的未签名 IPA。
