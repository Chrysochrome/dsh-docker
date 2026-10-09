# dsh-docker

把 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
每天构建一次，并发布成容器镜像到 GitHub Packages（GHCR）。

- `Dockerfile` — 从源码多阶段构建 harness。
- `.github/workflows/build.yml` — 每天 UTC 00:00（也可手动触发）构建并推送镜像到
  `ghcr.io/<owner>/dsh-docker`。

## 镜像标签

| 标签 | 含义 |
|---|---|
| `latest` | 最近一次成功构建 |
| `YYYYMMDD` | 构建日期 |
| `sha-<7位>` | 对应的上游 commit |

## 使用

### 从另一台电脑访问

在你自己的 Compose 文件中配置如下（`192.168.3.2` 仅为示例，请替换成实际地址）。
通过 `--host 0.0.0.0` 让容器监听所有网卡，用普通 Docker
bridge 端口映射，并用 `--trusted-host` 显式信任浏览器访问地址。
不要同时使用 `network_mode: host`。

```yaml
services:
  deepseek-harness:
    image: ghcr.io/<owner>/dsh-docker:latest
    restart: unless-stopped
    ports:
      - "192.168.3.2:3080:3080"
    command:
      - web
      - --host
      - "0.0.0.0"
      - --no-open
      - --trusted-host
      - "192.168.3.2:3080"
      - "192.168.3.2"
    volumes:
      - /your/host/dsh-home:/data
      - /your/host/projects:/workspace
```

保留你已有的环境变量、只读文件系统和 tmpfs 等配置。更新镜像并重新创建容器：

```sh
docker compose pull
docker compose up -d --force-recreate
docker compose logs --tail=100
```

从启动日志取出带 token 的 URL，将其中的 `127.0.0.1` 或 `localhost`
替换为运行容器的电脑 IP 地址（示例 `192.168.3.2`），保留端口、路径和 token。仅打开根地址可能返回 401。
此命令需要使用更新后的镜像。构建时允许上游 CLI 和 Web 服务配置层接受
`0.0.0.0`，保留其他地址校验。该处理兼容旧版 CLI 限制和新版通配地址限制；
若上游校验结构再次改变，构建会报错以便复核。
`DSH_TRUSTED_HOSTS` 环境变量不会由本镜像转换成启动参数，此示例直接传
`--trusted-host`。如需公网访问，应使用带访问认证的 HTTPS 反向代理。

### 在运行容器的电脑上访问

镜像默认监听 `0.0.0.0:3080`，本机访问时将端口发布到宿主机 loopback：

```sh
docker run --rm -p 127.0.0.1:3080:3080 \
  -e DEEPSEEK_API_KEY=sk-... \
  -e DSH_HOME=/data \
  -v /your/host/dsh-home:/data \
  -v /your/host/projects:/workspace \
  ghcr.io/<owner>/dsh-docker
```

然后浏览器打开启动日志里打印的 `dsh web:` URL。

> `docker run` 里的 `web` 是 `--profile web` 的官方简写；默认端口 **3080**。
> 想换端口就整体覆盖默认命令：`... dsh-docker web --host 0.0.0.0 --no-open --port 8080`
> （同时 `-e DSH_PORT=8080`，否则容器 `HEALTHCHECK` 会一直探 3080、显示 unhealthy）。

### dsh-home 与 workspace 是两码事，都可以放到容器外面

dsh 区分两个目录，各自都可以用 bind mount 映射到宿主机路径：

| | 是什么 | 怎么定义在「外面」 |
|---|---|---|
| **dsh-home**（`DSH_HOME`） | harness 的状态根：`.credentials.yaml`、`profiles/`、设置、会话、附件等 | `-e DSH_HOME=/data -v /your/host/dsh-home:/data`。解析优先级：显式配置 > `$DSH_HOME` > `~/.dsh` |
| **workspace** | agent 实际读写代码的目录，跟 dsh-home 完全分开 | 把宿主机目录 bind 进容器（`-v /your/host/projects:/workspace`），再在 Web UI 里「添加 workspace」选 `/workspace` |

> 注意两点：
> 1. 进程固定从 `/app` 启动（`tsx` 需要从 `/app/node_modules` 解析），所以**不要**用 `-w` 改工作目录，workspace 请在 Web UI 里添加。
> 2. 新开的 Web UI 默认没有任何 workspace，必须先手动加一个。

## 构建与发布

Actions 只负责拉取上游、构建镜像并发布到 GHCR，不启动容器或执行运行时测试。
运行验证由使用者在部署机器上手动进行。

手动运行 `workflow_dispatch` 时取消勾选 `push_image`，即可只构建、不推送。

镜像默认设置 `NARB_DISABLE_NATIVE_CACHE=1`，让原生加载器直接加载 `/app`
内的预编译绑定。该加载器默认会将 `.node` 复制到 `/tmp` 的缓存再加载；
如果部署环境对 `/tmp` 设置了 `noexec`，动态链接器无法加载缓存里的绑定。
这会导致同一镜像在 Actions 启动成功、在部署环境却报
`No usable native binding found`。社区实现也采用了
[关闭该缓存的处理](https://github.com/runzhliu/deepseek-harness-docker/blob/main/scripts/dsh-container)。

> 原生绑定 `node-addon-require-builtin` 是个「探测私有 Node/V8 状态，不匹配就
> fail-closed」的 N-API addon，对运行时环境比较敏感。为此构建里做了两件事：
> 用上游 `package.json` 的 `packageManager` 里锁定的 **pnpm 版本**（而不是写死一个
> 可能与仓库不兼容的旧版本）；并在 runtime 镜像里显式安装 **`libstdc++6`**
> （该 addon 要求 `GLIBCXX_3.4.25` 及以上的 C++ 运行时）。

## 已知限制 / 后续可优化

- 镜像较大（保留了完整源码 + node_modules，因为 `dsh` 走 tsx 源码执行）。
  后续可用 `pnpm deploy`、剔除 desktop/benchmark 依赖、删除 `.git` 来瘦身。
- 默认监听容器所有网卡，宿主机上的可访问地址由 Docker 端口映射决定。
- 定时任务在仓库 60 天无活动后会被 GitHub 自动停用；可加一个 keep-alive。

## 保留策略（只留最近一周）

每次推送镜像后，workflow 会跑一步清理，**删除 7 天前的所有镜像版本**，
只保留最近一周的构建，避免 Packages 容量无限增长。

- 由 [`dataaxiom/ghcr-cleanup-action`](https://github.com/dataaxiom/ghcr-cleanup-action) 完成，
  规则是 `older-than: 7 days` + `delete-tags: '*'`。
- 注意 `older-than` 的语义是「把**所有**规则限制在比该时长更老的镜像上」，
  所以这是「删掉 7 天前的」，**不是**「保留最老的 N 个」——这两个方向很容易搞反。
- `latest` 被 `exclude-tags` 保护，任何时候都至少留一个可用镜像。
- 只在**真正推送了镜像**时才执行（手动 build-only 测试不会触发清理）。
- 顺带清掉残留的 untagged manifest（platform / attestation）和父镜像已消失的 referrer。

调整保留窗口就改 `build.yml` 里 `older-than` 的值（支持 `days` / `weeks` / `months` / `years`）。

> ⚠️ 用 `GITHUB_TOKEN` 删包版本，需要该 package 给本仓库 **Admin** 权限：
> 仓库 → Packages → 选中该包 → Package settings → Manage Actions access → 给本仓库 Admin。
> 否则清理步骤会 403。
