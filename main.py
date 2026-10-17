#!/usr/bin/env python3
"""使用 Camoufox 打开网页, 并通过 Kryva 管理浏览器 profile。"""

from __future__ import annotations

import argparse
import asyncio
import os
import shutil
import stat
import sys
import tarfile
import tempfile
import unicodedata
from collections.abc import Callable, Sequence
from pathlib import Path, PurePosixPath
from typing import TypeVar
from urllib.parse import unquote, urlsplit

import requests

Item = TypeVar("Item")

DATA_DIR = Path(__file__).resolve().parent / "data"
KRYVA_DEFAULT_API_URL = "https://kryva.oozuo.com/"
KRYVA_PLATFORM = "profile"
KRYVA_TIMEOUT = (15, 600)
PROFILE_ARCHIVE_SUFFIX = ".tar.gz"
SQLITE_SUFFIXES = ("", "-wal", "-shm", "-journal")
ARCHIVE_ERRORS = (OSError, RuntimeError, requests.RequestException, tarfile.TarError)


def profile_archive_name(profile: str) -> str:
    """返回 Kryva 与本地共用的 NFC 规范化 profile 归档文件名。"""
    return f"{unicodedata.normalize('NFC', profile)}{PROFILE_ARCHIVE_SUFFIX}"


class ProfileArchive:
    """筛选、打包并恢复浏览器 profile 中的站点数据。"""

    PROFILE_DATABASES = {
        f"{name}{suffix}"
        for name in ("cookies.sqlite", "webappsstore.sqlite", "storage.sqlite")
        for suffix in SQLITE_SUFFIXES
    }
    LS_ARCHIVE_FILES = {
        f"storage/ls-archive.sqlite{suffix}" for suffix in SQLITE_SUFFIXES
    }

    def __init__(self, data_dir: Path) -> None:
        """记录包含全部 profile 的数据目录。"""
        self.data_dir = data_dir

    def profile_path(self, profile: str) -> Path:
        """返回 profile 目录并拒绝可能越出数据目录的符号链接。"""
        if self.data_dir.is_symlink():
            raise RuntimeError("data 目录不能是符号链接")
        path = self.data_dir / profile
        if path.is_symlink():
            raise RuntimeError("profile 目录不能是符号链接")
        if path.exists() and not path.is_dir():
            raise RuntimeError("profile 路径必须是目录")
        return path

    @classmethod
    def is_profile_data_file(cls, relative: PurePosixPath) -> bool:
        """判断相对路径是否属于 Cookies、localStorage 或 IndexedDB。"""
        path = relative.as_posix()
        if path in cls.PROFILE_DATABASES or path in cls.LS_ARCHIVE_FILES:
            return True
        parts = relative.parts
        if (
            len(parts) < 4
            or parts[0] != "storage"
            or parts[1] not in {"default", "permanent", "temporary"}
        ):
            return False
        if parts[2].startswith("moz-extension"):
            return False
        if len(parts) == 4 and parts[3] in {".metadata", ".metadata-v2"}:
            return True
        return len(parts) >= 5 and parts[3] in {"ls", "idb"}

    def collect_files(self, profile: str) -> list[tuple[Path, PurePosixPath]]:
        """收集 profile 中允许备份的普通文件。"""
        root = self.profile_path(profile)
        if not root.exists():
            raise RuntimeError(f"profile 不存在: {profile}")
        selected: list[tuple[Path, PurePosixPath]] = []
        for current_root, directories, files in os.walk(root, followlinks=False):
            current = Path(current_root)
            directories[:] = sorted(
                name for name in directories if not (current / name).is_symlink()
            )
            for name in sorted(files):
                source = current / name
                if source.is_symlink() or not stat.S_ISREG(
                    source.stat(follow_symlinks=False).st_mode
                ):
                    continue
                relative = PurePosixPath(source.relative_to(root).as_posix())
                if self.is_profile_data_file(relative):
                    selected.append((source, relative))
        return selected

    def create(self, profile: str, destination: Path) -> bool:
        """将 profile 的站点数据写入 gzip tar 归档。"""
        files = self.collect_files(profile)
        if not files:
            return False
        with tarfile.open(destination, mode="w:gz") as archive:
            for source, relative in files:
                archive_name = PurePosixPath(profile, relative)
                info = archive.gettarinfo(str(source), arcname=archive_name.as_posix())
                if not info.isfile():
                    continue
                with source.open("rb") as stream:
                    archive.addfile(info, stream)
        return True

    def validate_members(
        self,
        profile: str,
        archive: tarfile.TarFile,
    ) -> list[tuple[tarfile.TarInfo, PurePosixPath]]:
        """校验归档成员并返回允许恢复的普通文件。"""
        selected: list[tuple[tarfile.TarInfo, PurePosixPath]] = []
        seen: set[str] = set()
        for member in archive.getmembers():
            member_path = PurePosixPath(member.name)
            if (
                member_path.is_absolute()
                or ".." in member_path.parts
                or not member_path.parts
            ):
                raise RuntimeError("Kryva 归档包含非法路径")
            if member.isdir():
                if member_path.parts[0] != profile:
                    raise RuntimeError("Kryva 归档包含非目标 profile 目录")
                continue
            if (
                not member.isfile()
                or member_path.parts[0] != profile
                or len(member_path.parts) < 2
            ):
                raise RuntimeError("Kryva 归档包含非目标 profile 文件")
            relative = PurePosixPath(*member_path.parts[1:])
            if not self.is_profile_data_file(relative):
                raise RuntimeError("Kryva 归档包含非站点数据")
            key = relative.as_posix()
            if key in seen:
                raise RuntimeError("Kryva 归档包含重复文件")
            seen.add(key)
            selected.append((member, relative))
        if not selected:
            raise RuntimeError("Kryva 归档中没有可恢复的站点数据")
        return selected

    def extract(self, profile: str, archive_path: Path) -> None:
        """将归档中的白名单文件原子写入指定 profile。"""
        target_root = self.profile_path(profile)
        with tarfile.open(archive_path, mode="r:gz") as archive:
            members = self.validate_members(profile, archive)
            target_root.mkdir(parents=True, exist_ok=True)
            for member, relative in members:
                source = archive.extractfile(member)
                if source is None:
                    raise RuntimeError("无法读取 Kryva 归档文件")
                parent = target_root
                for part in relative.parts[:-1]:
                    parent /= part
                    if parent.is_symlink():
                        raise RuntimeError("profile 包含指向目录外的符号链接")
                    parent.mkdir(exist_ok=True)
                destination = parent / relative.name
                if destination.is_symlink():
                    raise RuntimeError("profile 包含指向目录外的符号链接")
                temporary: Path | None = None
                try:
                    with source, tempfile.NamedTemporaryFile(
                        dir=parent, delete=False
                    ) as output:
                        temporary = Path(output.name)
                        shutil.copyfileobj(source, output, length=1024 * 1024)
                    temporary.replace(destination)
                except Exception:
                    if temporary is not None:
                        temporary.unlink(missing_ok=True)
                    raise


class KryvaClient:
    """使用 requests 调用 Kryva 文件上传和下载接口。"""

    def __init__(
        self, api_key: str, api_url: str, session: requests.Session | None = None
    ) -> None:
        """初始化 Kryva HTTP 会话。"""
        self.api_key = api_key
        self.api_url = api_url.rstrip("/")
        self.session = session or requests.Session()

    @classmethod
    def from_environment(cls) -> KryvaClient:
        """从系统环境变量创建 Kryva 客户端。"""
        api_key = os.environ.get("KRYVA_API_KEY", "").strip()
        api_url = os.environ.get("KRYVA_API_URL", "").strip() or KRYVA_DEFAULT_API_URL
        if not api_key:
            raise RuntimeError("KRYVA_API_KEY 未配置")
        return cls(api_key, api_url)

    def endpoint(self, path: str) -> str:
        """返回 Kryva API 的完整地址。"""
        return f"{self.api_url}/{path.lstrip('/')}"

    def raise_for_status(self, response: requests.Response) -> None:
        """将 Kryva 非成功响应转换为不包含凭据的错误。"""
        if 200 <= response.status_code < 300:
            return
        if response.status_code == 401:
            raise RuntimeError("KRYVA_API_KEY 无效")
        detail = response.text.strip()
        message = f"Kryva 请求失败, HTTP {response.status_code}"
        if detail:
            message = f"{message}: {detail[:500]}"
        raise RuntimeError(message)

    def upload(self, profile: str, archive: Path) -> None:
        """使用固定 platform 和 profile 文件名上传归档。"""
        filename = profile_archive_name(profile)
        with archive.open("rb") as stream:
            response = self.session.post(
                self.endpoint("/api/v1/files/upload"),
                headers={"Authorization": f"Bearer {self.api_key}"},
                data={"platform": KRYVA_PLATFORM},
                files={"file": (filename, stream, "application/gzip")},
                timeout=KRYVA_TIMEOUT,
            )
        self.raise_for_status(response)

    def download(self, profile: str, destination: Path) -> bool:
        """按 platform 和 profile 文件名下载最新归档。"""
        response = self.session.get(
            self.endpoint("/api/v1/files/download"),
            headers={"Authorization": f"Bearer {self.api_key}"},
            params={
                "platform": KRYVA_PLATFORM,
                "filename": profile_archive_name(profile),
            },
            timeout=KRYVA_TIMEOUT,
            stream=True,
        )
        with response:
            if response.status_code == 404:
                return False
            self.raise_for_status(response)
            with destination.open("wb") as output:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        output.write(chunk)
        return True


class BrowserApp:
    """提供浏览器启动、profile 备份和 profile 恢复命令。"""

    def __init__(self, data_dir: Path = DATA_DIR) -> None:
        """初始化 profile 数据目录和归档服务。"""
        self.data_dir = data_dir
        self.archives = ProfileArchive(data_dir)

    @staticmethod
    def format_size(size: int) -> str:
        """将字节数格式化为易读的 B/KB/MB/GB 文本。"""
        value = float(size)
        unit = "B"
        for candidate in ("KB", "MB", "GB"):
            if value < 1024:
                break
            value /= 1024
            unit = candidate
        if unit == "B":
            return f"{size} B"
        return f"{value:.1f} {unit}"

    def local_archive(self, profile: str) -> Path:
        """返回 data 目录下 profile 的本地压缩包路径。"""
        return self.data_dir / profile_archive_name(profile)

    def profile_directories(self) -> list[str]:
        """返回 data 目录下可备份的 profile 目录名。"""
        if not self.data_dir.is_dir():
            return []
        return sorted(
            entry.name
            for entry in self.data_dir.iterdir()
            if entry.is_dir() and not entry.is_symlink()
        )

    def profile_names(self) -> list[str]:
        """返回 data 目录下所有已知 profile 名, 含目录与本地压缩包。"""
        if not self.data_dir.is_dir():
            return []
        names: set[str] = set()
        for entry in self.data_dir.iterdir():
            if entry.is_symlink():
                continue
            if entry.is_dir():
                names.add(entry.name)
            elif entry.is_file() and entry.name.endswith(PROFILE_ARCHIVE_SUFFIX):
                names.add(entry.name[: -len(PROFILE_ARCHIVE_SUFFIX)])
        return sorted(names)

    @staticmethod
    def select_profile(
        profiles: Sequence[str],
        action: str,
        describe: Callable[[str], str] | None = None,
    ) -> str | None:
        """列出 profile 供用户输入序号选择; 输入 q 或 EOF 时返回 None。"""
        if not profiles:
            print(f"data 目录下没有可{action}的 profile")
            return None
        for index, name in enumerate(profiles, start=1):
            note = describe(name) if describe else ""
            print(f"{index}. {name}{note}")
        while True:
            try:
                choice = input(f"请选择要{action}的 profile 序号, 输入 q 取消: ")
            except EOFError:
                print()
                return None
            choice = choice.strip()
            if choice.lower() == "q":
                return None
            if choice.isdigit() and 1 <= int(choice) <= len(profiles):
                return profiles[int(choice) - 1]
            print("序号无效, 请重新输入")

    @classmethod
    def build_parser(cls) -> argparse.ArgumentParser:
        """创建包含 start、backup 和 restore 的参数解析器。"""
        parser = argparse.ArgumentParser(
            description="使用 Camoufox 打开网页并管理浏览器 profile"
        )
        commands = parser.add_subparsers(dest="command", required=True)

        start_parser = commands.add_parser("start", help="启动浏览器")
        start_parser.add_argument(
            "--url",
            default="https://muse.ai",
            help="需要打开的完整 URL",
        )
        start_parser.add_argument(
            "--profile",
            metavar="NAME",
            help="将数据持久化到 ./data/NAME",
        )
        start_parser.add_argument(
            "--proxy",
            metavar="SERVER|null",
            help="代理地址, 如 socks5://user:pass@127.0.0.1:40000; 传 null 则不使用代理",
        )
        start_parser.add_argument(
            "--locale",
            default="en-US",
            help="浏览器 locale, 默认 en-US, 也可用 us 或逗号分隔的列表",
        )

        backup_parser = commands.add_parser("backup", help="备份浏览器 profile")
        backup_target = backup_parser.add_mutually_exclusive_group()
        backup_target.add_argument(
            "--profile",
            metavar="NAME",
            help="指定 profile; 省略此选项与 --all 时列出所有 profile 供选择",
        )
        backup_target.add_argument(
            "--all",
            action="store_true",
            help="备份 data 目录下的所有 profile",
        )
        backup_parser.add_argument(
            "--no-upload",
            action="store_true",
            help="备份文件不上传 Kryva, 压缩包始终保留在 data 目录",
        )

        restore_parser = commands.add_parser("restore", help="恢复浏览器 profile")
        restore_target = restore_parser.add_mutually_exclusive_group()
        restore_target.add_argument(
            "--profile",
            metavar="NAME",
            help="指定 profile; 省略此选项与 --all 时列出所有 profile 供选择",
        )
        restore_target.add_argument(
            "--all",
            action="store_true",
            help="恢复 data 目录下所有本地压缩包",
        )
        return parser

    @staticmethod
    async def wait_for_exit() -> None:
        """等待用户输入 exit 后继续退出流程。"""
        while True:
            try:
                command = await asyncio.to_thread(input, "请输入 exit 关闭浏览器: ")
            except EOFError:
                return
            if command.strip().lower() == "exit":
                return

    @staticmethod
    def parse_proxy(proxy: str) -> dict[str, str]:
        """解析代理地址; 含用户名或密码时拆分为独立字段。"""
        parsed = urlsplit(proxy)
        if not parsed.scheme or not parsed.hostname:
            return {"server": proxy}
        try:
            port = parsed.port
        except ValueError as error:
            raise RuntimeError(f"代理端口无效: {proxy}") from error
        server = f"{parsed.scheme}://{parsed.hostname}"
        if port is not None:
            server = f"{server}:{port}"
        options = {"server": server}
        if parsed.username is not None:
            options["username"] = unquote(parsed.username)
        if parsed.password is not None:
            options["password"] = unquote(parsed.password)
        return options

    async def open_url(
        self,
        url: str,
        profile: str | None = None,
        proxy: str | None = None,
        locale: str = "en-US",
    ) -> None:
        """启动可见浏览器, 并按需使用持久化上下文、指定代理和 locale。"""
        from camoufox.async_api import AsyncCamoufox

        options: dict[str, object] = {
            "headless": False,
            "geoip": True,
            "locale": locale,
        }
        if proxy == "null":
            pass
        elif proxy:
            options["proxy"] = self.parse_proxy(proxy)
        else:
            options["firefox_user_prefs"] = {
                "network.proxy.type": 1,
                "network.proxy.socks": "127.0.0.1",
                "network.proxy.socks_port": 40000,
                "network.proxy.socks_version": 5,
                "network.proxy.socks_remote_dns": True,
            }
        if profile:
            profile_dir = self.archives.profile_path(profile)
            profile_dir.mkdir(parents=True, exist_ok=True)
            options.update(persistent_context=True, user_data_dir=str(profile_dir))
        async with AsyncCamoufox(**options) as browser:
            page = await browser.new_page()
            await page.goto(url, wait_until="domcontentloaded")
            print(f"已打开: {page.url} | {await page.title()}")
            await self.wait_for_exit()

    def create_archive(self, profile: str, archive: Path) -> bool:
        """创建归档; 没有站点数据时输出提示并返回 False。"""
        if self.archives.create(profile, archive):
            return True
        print(
            f"profile={profile} 没有 Cookies, localStorage 或 IndexedDB 数据, 跳过备份"
        )
        return False

    def backup(self, profile: str, upload: bool = True) -> int:
        """创建指定 profile 的站点数据归档, 按需上传 Kryva, 成功后删除 profile 目录。"""
        archive = self.local_archive(profile)
        if not self.create_archive(profile, archive):
            return 0
        if upload:
            KryvaClient.from_environment().upload(profile, archive)
            print(
                f"已备份: platform={KRYVA_PLATFORM}, "
                f"filename={archive.name}, path={archive.resolve()}"
            )
        else:
            print(
                f"已备份(未上传): path={archive.resolve()}, "
                f"size={self.format_size(archive.stat().st_size)}"
            )
        profile_dir = self.archives.profile_path(profile)
        shutil.rmtree(profile_dir)
        print(f"已删除 profile 目录: {profile_dir}")
        return 0

    def run_each(
        self,
        items: Sequence[Item],
        action: str,
        operation: Callable[[Item], int | None],
    ) -> int:
        """逐个执行操作, 单个失败输出 stderr 但不中断, 返回是否全部成功。"""
        failed = 0
        for item in items:
            try:
                if operation(item):
                    failed += 1
            except ARCHIVE_ERRORS as error:
                print(f"{action} {item} 失败: {error}", file=sys.stderr)
                failed += 1
        return 1 if failed else 0

    def backup_all(self, upload: bool = True) -> int:
        """备份 data 目录下所有 profile 目录, 单个失败不中断其余备份。"""
        profiles = self.profile_directories()
        if not profiles:
            print(f"data 目录下没有 profile: {self.data_dir}")
            return 0
        return self.run_each(
            profiles, "备份", lambda profile: self.backup(profile, upload=upload)
        )

    def restore_local(self, profile: str, archive: Path) -> None:
        """从本地压缩包恢复 profile 并输出结果。"""
        self.archives.extract(profile, archive)
        print(f"已恢复(本地): path={archive.resolve()}, filename={archive.name}")

    def restore(self, profile: str) -> int:
        """优先从本地 data 目录恢复, 否则从 Kryva 下载归档再恢复。"""
        archive = self.local_archive(profile)
        if archive.is_file():
            self.restore_local(profile, archive)
            return 0
        with tempfile.TemporaryDirectory(
            prefix="webtop-restore-"
        ) as temporary_dir:
            downloaded = Path(temporary_dir) / archive.name
            if not KryvaClient.from_environment().download(profile, downloaded):
                print(f"profile={profile} 暂无可恢复的 Kryva 备份")
                return 0
            self.archives.extract(profile, downloaded)
        print(f"已恢复: platform={KRYVA_PLATFORM}, filename={archive.name}")
        return 0

    def restore_archive(self, archive: Path) -> None:
        """恢复单个本地压缩包, 不回退 Kryva。"""
        profile = archive.name[: -len(PROFILE_ARCHIVE_SUFFIX)]
        self.restore_local(profile, archive)

    def restore_all(self) -> int:
        """恢复 data 目录下所有本地压缩包, 单个失败不中断其余恢复。"""
        archives = (
            sorted(self.data_dir.glob(f"*{PROFILE_ARCHIVE_SUFFIX}"))
            if self.data_dir.is_dir()
            else []
        )
        if not archives:
            print(f"data 目录下没有本地压缩包: {self.data_dir}")
            return 0
        return self.run_each(archives, "恢复", self.restore_archive)

    def run(self, argv: Sequence[str] | None = None) -> int:
        """解析命令并执行对应操作。"""
        args = self.build_parser().parse_args(argv)
        try:
            if args.command == "start":
                asyncio.run(
                    self.open_url(args.url, args.profile, args.proxy, args.locale)
                )
                return 0
            if args.command == "backup":
                return self.run_backup(args)
            return self.run_restore(args)
        except ARCHIVE_ERRORS as error:
            print(str(error), file=sys.stderr)
            return 1

    def run_backup(self, args: argparse.Namespace) -> int:
        """按 --all、--profile 或交互选择执行备份。"""
        upload = not args.no_upload
        if args.all:
            return self.backup_all(upload=upload)
        profile = args.profile or self.select_profile(
            self.profile_directories(), "备份"
        )
        if profile is None:
            return 0
        return self.backup(profile, upload=upload)

    def run_restore(self, args: argparse.Namespace) -> int:
        """按 --all、--profile 或交互选择执行恢复。"""
        if args.all:
            return self.restore_all()
        profile = args.profile or self.select_profile(
            self.profile_names(), "恢复", describe=self.describe_restore_source
        )
        if profile is None:
            return 0
        return self.restore(profile)

    def describe_restore_source(self, profile: str) -> str:
        """标注交互列表中 profile 的恢复来源。"""
        if self.local_archive(profile).is_file():
            return " (本地压缩包)"
        return " (尝试 Kryva)"


def main(argv: Sequence[str] | None = None) -> int:
    """创建应用并运行命令行入口。"""
    try:
        return BrowserApp().run(argv)
    except KeyboardInterrupt:
        print()
        return 130


if __name__ == "__main__":
    sys.exit(main())
