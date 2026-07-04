# GitHub + VPS 一键部署说明

本文档用于把当前 Discuz 源码通过 GitHub 管理，并在 VPS 上自动部署和更新。

## 1. 本地首次推送到 GitHub

```bash
cd Discuz_X5.0_20260701
git init
git add .
git commit -m "Initial secured Discuz source"
git branch -M main
git remote add origin git@github.com:YOUR_NAME/YOUR_REPO.git
git push -u origin main
```

不要提交生产配置和运行时数据：`.gitignore` 已排除 `upload/config/config_global.php`、`upload/config/config_ucenter.php` 和 `upload/data` 运行时内容。

## 2. VPS 首次部署

```bash
git clone git@github.com:YOUR_NAME/YOUR_REPO.git /tmp/forum-src
cd /tmp/forum-src
SERVER_NAME=your-domain.com sudo -E bash scripts/deploy.sh
```

如果暂时没有域名，可以省略 `SERVER_NAME`：

```bash
sudo bash scripts/deploy.sh
```

脚本会自动完成：

- 安装 `nginx`、`mariadb-server`、`php-fpm`、常用 PHP 扩展、`git` 和 `rsync`。
- 把代码部署到 `/var/www/discuz-forum/repo`。
- 创建数据库、数据库用户和随机数据库密码。
- 生成 Discuz 配置和 UCenter 配置。
- 自动初始化数据库、UCenter 和 Discuz 基础数据。
- 自动创建管理员账号：`admin / qwer@1234`。
- 生成 `upload/data/install.lock` 并配置 Nginx 阻止安装器再次访问。
- 修复 `upload/config` 和 `upload/data` 权限。

默认使用 HTTP。若你已经准备好域名和 HTTPS 反向代理，可通过环境变量启用 Discuz 强制 HTTPS：

```bash
SERVER_NAME=your-domain.com ENABLE_HTTPS=1 sudo -E bash scripts/deploy.sh
```

## 3. 日常更新

```bash
sudo bash /var/www/discuz-forum/repo/scripts/update.sh
```

更新脚本会自动执行 `git fetch`、切换到 `origin/main`、PHP 语法检查、权限修复和服务重载。

## 4. 安全提醒

你指定的默认管理员密码是固定值，方便一键部署；正式上线后建议尽快在后台修改密码。数据库密码和站点 `authkey` 仍由脚本随机生成，保存在 `/var/www/discuz-forum/.secrets/`。
