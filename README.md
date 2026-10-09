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
  -v dsh-home:/data \
  ghcr.io/<owner>/dsh-docker
```

然后浏览器打开启动日志里打印的 `dsh web:` URL。

覆盖参数（启动器自带 flag 之后的参数会透传给 web app）：

```sh
docker run --rm --network host ghcr.io/<owner>/dsh-docker web --no-open --port 8080
```

## 已知限制 / 后续可优化

- 镜像较大（保留了完整源码 + node_modules，因为 `dsh` 走 tsx 源码执行）。
  后续可用 `pnpm deploy`、剔除 desktop/benchmark 依赖、删除 `.git` 来瘦身。
- 只监听 loopback：跨机访问需要 `--network host`，或在同 netns 里放反向代理 +
  `--trusted-host`。
- 定时任务在仓库 60 天无活动后会被 GitHub 自动停用；可加一个 keep-alive。
