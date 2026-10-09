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

Web 服务只监听容器内 loopback（上游禁止 `--host 0.0.0.0`），所以要用 host 网络：

```sh
docker run --rm --network host \
  -e DEEPSEEK_API_KEY=sk-... \
  -e DSH_HOME=/data \
  -v /your/host/dsh-home:/data \
  -v /your/host/projects:/workspace \
  ghcr.io/<owner>/dsh-docker
```

然后浏览器打开启动日志里打印的 `dsh web:` URL。

> `docker run` 里的 `web` 是 `--profile web` 的官方简写；默认端口 **3080**。
> 想换端口就整体覆盖默认命令：`... dsh-docker web --no-open --port 8080`
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

## CI 自检（Smoke test）

每次构建（定时 / 手动 / push）之后，workflow 都会自动**启动容器**验证运行时，
不需要你本地有 docker：

0. 打印运行时诊断：`process.versions`、`node-addon-require-builtin` 的版本、
   预编译 `.node` 是否存在、它的 `ldd` 依赖，以及从实际消费者 `vendor/loader`
   解析依赖时 `require()` 的**完整**错误（避免 pnpm 下从根目录加载不到间接依赖）
   （原生加载器会把真正的 dlopen/ABI 错误藏进嵌套的 `attempts`，默认会被折叠掉）。
1. `dsh web --help` — 验证镜像能启动、`tsx` 能从 `/app/node_modules` 正确解析、
   CLI 与 web 插件能加载（`--help` 只打印帮助、不真正 bind）。
2. 分离模式启动 `web --no-open`，轮询日志等待上游文档定义的 readiness 信号
   `dsh web:` 行出现（最多 ~5 分钟）。
3. `curl http://127.0.0.1:3080/`，只要不是 `000`（连不上）就算通过——
   启动 URL 带进程 token，所以 401/403 也算端口正常。
4. 无论成败都会把容器日志打进 workflow，失败时直接能看见原因。

启动与 HTTP 检查会分别覆盖普通容器，以及只读根文件系统、带 `noexec`
的 `/tmp` tmpfs、`no-new-privileges` 和 `cap_drop: ALL` 的容器。
两种环境都通过后才推送 GHCR，失败时不会覆盖已发布的 `latest`。

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

> 如果仍报 `No usable native binding found`，请查看 Actions 的
> `native binding diagnostics` 分组中最内层 `attempts` 的 `message`。
> 平台包已安装但加载失败时，后续 `build/nodeabi`、`build/napi` 的
> `MODULE_NOT_FOUND` 只是本地备用产物不存在，不是预编译绑定失败的根因。
> 发布的 addon 不包含原生源码，不能靠 `pnpm rebuild` 补出这些产物。


手动跑一次 `workflow_dispatch`、把 `push_image` 取消勾选，就是「只构建 + 自检、不推包」。

## 已知限制 / 后续可优化

- 镜像较大（保留了完整源码 + node_modules，因为 `dsh` 走 tsx 源码执行）。
  后续可用 `pnpm deploy`、剔除 desktop/benchmark 依赖、删除 `.git` 来瘦身。
- 只监听 loopback：跨机访问需要 `--network host`，或在同 netns 里放反向代理 +
  `--trusted-host`。
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
