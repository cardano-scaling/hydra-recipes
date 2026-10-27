#!/usr/bin/env python3
"""Exercise real Cardano/Hydra processes on an isolated, disposable devnet."""

import argparse
from contextlib import ExitStack, contextmanager
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request

import websocket
import yaml


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def lovelace(utxo, address=None):
    return sum(v["value"]["lovelace"] for v in utxo.values()
               if address is None or v["address"] == address)


class Lifecycle:
    def __init__(self, args, work, cleanup):
        self.args, self.work, self.cleanup = args, work, cleanup
        self.logs = work / "logs"
        self.logs.mkdir()
        self.processes = []
        self.socket = work / "node.socket"
        self.report = {"status": "running", "networkMagic": 42, "phases": []}

    def record(self, phase, **details):
        self.report["phases"].append({
            "phase": phase,
            "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            **details,
        })
        print(f"PASS: {phase}", flush=True)

    def run(self, args, *, cwd=None, env=None, timeout=120):
        result = subprocess.run(
            [str(x) for x in args], cwd=cwd or self.work, env=env,
            text=True, capture_output=True, timeout=timeout,
        )
        with (self.logs / "commands.log").open("a") as log:
            log.write(f"$ {' '.join(str(x) for x in args)}\n")
            log.write(result.stdout + result.stderr)
        result.check_returncode()
        return result.stdout.strip()

    def cli(self, *args):
        return self.run(["cardano-cli", "latest", *args])

    def query(self, *args):
        return json.loads(self.cli("query", *args, "--socket-path", self.socket,
                                   "--testnet-magic", "42"))

    def utxos(self, address):
        return self.query("utxo", "--address", address, "--out-file", "/dev/stdout")

    def wait(self, description, predicate, timeout=120):
        deadline = time.monotonic() + timeout
        last_error = None
        while time.monotonic() < deadline:
            for process, name in self.processes:
                if process.poll() is not None:
                    raise RuntimeError(f"{name} exited {process.returncode}; see its log")
            try:
                result = predicate()
                if result:
                    return result
            except (OSError, subprocess.CalledProcessError) as error:
                last_error = error
            time.sleep(0.5)
        raise TimeoutError(f"Timed out waiting for {description}: {last_error}")

    def start(self, name, args, cwd=None, env=None, cleanup=None):
        with (self.logs / f"{name}.log").open("a") as log:
            process = subprocess.Popen(
                [str(x) for x in args], cwd=cwd or self.work, env=env,
                stdout=log, stderr=log, start_new_session=True,
            )
        self.processes.append((process, name))
        (cleanup or self.cleanup).callback(self.stop, process)

    def stop(self, process):
        self.processes = [(p, n) for p, n in self.processes if p is not process]
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def submit(self, signed):
        txid = self.cli("transaction", "txid", "--tx-file", signed, "--output-text")
        self.cli("transaction", "submit", "--tx-file", signed,
                 "--socket-path", self.socket, "--testnet-magic", "42")
        return txid

    def prepare_chain(self):
        devnet = self.work / "devnet"
        shutil.copytree(self.args.hydra_config / "devnet", devnet)
        devnet.chmod(0o700)
        for file in devnet.iterdir():
            file.chmod(0o600)
        start = int(time.time())
        byron = json.loads((devnet / "genesis-byron.json").read_text())
        byron["startTime"] = start
        write_json(devnet / "genesis-byron.json", byron)
        shelley = json.loads((devnet / "genesis-shelley.json").read_text())
        shelley["systemStart"] = datetime.datetime.fromtimestamp(
            start, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        write_json(devnet / "genesis-shelley.json", shelley)
        write_json(devnet / "topology.json", {"localRoots": [], "publicRoots": []})
        self.start("cardano-node", [
            "cardano-node", "run", "--config", devnet / "cardano-node.json",
            "--topology", devnet / "topology.json", "--database-path", devnet / "db",
            "--socket-path", self.socket, "--host-addr", "127.0.0.1", "--port", port(),
            "--shelley-kes-key", devnet / "kes.skey",
            "--shelley-vrf-key", devnet / "vrf.skey",
            "--shelley-operational-certificate", devnet / "opcert.cert",
            "--byron-delegation-certificate", devnet / "byron-delegation.cert",
            "--byron-signing-key", devnet / "byron-delegate.key",
        ])
        self.wait("devnet synchronization", lambda: self.query("tip").get("syncProgress") == "100.00")
        self.report["versions"] = {
            "hydra": self.run(["hydra-node", "--version"]),
            "cardano-node": self.run(["cardano-node", "--version"]),
            "cardano-cli": self.run(["cardano-cli", "version"]),
        }
        self.record("Cardano devnet synchronized")

    def seed(self):
        faucet = self.args.hydra_config / "credentials" / "faucet"
        address = self.cli("address", "build", "--payment-verification-key-file",
                           str(faucet) + ".vk", "--testnet-magic", "42")
        utxo = self.utxos(address)
        seed = self.work / "seed.json"
        outputs = [arg for peer in self.peers
                   for arg in ("--tx-out", f"{peer.address('funds')}+100000001")]
        self.cli("transaction", "build", "--tx-in", next(iter(utxo)), *outputs,
                 "--change-address", address, "--out-file", seed,
                 "--socket-path", self.socket, "--testnet-magic", "42")
        signed = self.work / "seed.signed"
        self.cli("transaction", "sign", "--tx-body-file", seed,
                 "--signing-key-file", str(faucet) + ".sk", "--out-file", signed)
        txid = self.submit(signed)
        self.wait("funds arriving", lambda: all(self.utxos(p.address("funds")) for p in self.peers))
        self.record("Both funds addresses seeded", transaction=txid)
        self.scripts = self.run([
            "hydra-node", "publish-scripts", "--node-socket", self.socket,
            "--testnet-magic", "42", "--cardano-signing-key", str(faucet) + ".sk",
        ])
        if not all(len(txid) == 64 and all(c in "0123456789abcdef" for c in txid)
                   for txid in self.scripts.split(",")):
            raise RuntimeError(f"Unexpected publish-scripts output: {self.scripts}")
        self.record("Hydra scripts published", transactions=self.scripts.split(","))

    @contextmanager
    def running_peers(self):
        with ExitStack() as cleanup:
            for peer in self.peers:
                peer.start(cleanup)
            for peer in self.peers:
                peer.connect(cleanup)
            yield

    def exercise(self):
        self.prepare_chain()
        self.peers = [Peer(self, "alice"), Peer(self, "bob", docker=self.args.docker_peer)]
        self.seed()
        for peer in self.peers:
            peer.configure()
            peer.distribute()
        self.record("Fuel distribution confirmed for both peers")
        alice, bob = self.peers

        with self.running_peers():
            self.record("Both peers synchronized", recipes={p.name: p.recipe for p in self.peers})
            alice.send("Init")
            heads = [p.wait_tag("HeadIsOpen")["headId"] for p in self.peers]
            assert heads[0] == heads[1], "Peers observed different heads"
            self.report["headId"] = heads[0]
            self.record("Head opened on both peers")

            # Hydra 2.4 opens an empty head on Init; /commit deposits into that head.
            for peer in self.peers:
                utxo = self.utxos(peer.address("funds"))
                peer.committed_lovelace = lovelace(utxo)
                path = self.work / f"{peer.name}-commit.json"
                signed = self.work / f"{peer.name}-commit.signed"
                write_json(path, peer.http("/commit", utxo))
                self.cli("transaction", "sign", "--tx-file", path, "--signing-key-file",
                         peer.root / "credentials/funds.sk", "--out-file", signed)
                txid = self.submit(signed)
                for observer in self.peers:
                    finalized = observer.wait_tag("CommitFinalized")
                    assert finalized["depositTxId"] == txid, "Wrong deposit finalized"
                self.record(f"{peer.name} deposit finalized on both peers", transaction=txid)

            snapshot = alice.http("/snapshot/utxo")
            assert snapshot and snapshot == bob.http("/snapshot/utxo"), "Snapshots differ"
            assert {v["address"] for v in snapshot.values()} == {p.address("funds") for p in self.peers}, \
                "Missing committed funds"
            for peer in self.peers:
                assert lovelace(snapshot, peer.address("funds")) == peer.committed_lovelace, \
                    "Committed ada missing from snapshot"
            self.record("Both peers agree on committed UTxO", outputs=len(snapshot))

        with self.running_peers():
            for peer in self.peers:
                assert peer.http("/snapshot/utxo") == snapshot, "Restart lost committed funds"
            self.record("Both peers restarted and recovered the same open head")
            alice.send("Close")
            for peer in self.peers:
                peer.wait_tag("HeadIsClosed")
                peer.wait_tag("ReadyToFanout")
            self.record("Head closed and contestation period elapsed")
            bob.send("Fanout")
            for peer in self.peers:
                final = peer.wait_tag("HeadIsFinalized")
                assert final["headId"] == heads[0], "Wrong head finalized"
            for peer in self.peers:
                self.wait(f"{peer.name} funds returned to L1", lambda p=peer:
                          lovelace(self.utxos(p.address("funds"))) == p.committed_lovelace)
            self.record("Fanout finalized on both peers and committed ada returned to L1")
        self.report["status"] = "passed"


class Peer:
    def __init__(self, test, name, docker=False):
        self.test, self.name, self.docker = test, name, docker
        self.recipe = "docker" if docker else "existing-node"
        self.root = test.work / name
        self.api, self.network, self.monitor, self.pc_port = port(), port(), port(), port()
        self.connection = None
        self.container = f"hydra-recipes-test-{test.work.name}-{name}"
        for folder in ["config", "scripts", "recipes"]:
            shutil.copytree(test.args.recipe_root / folder, self.root / folder)
        (self.root / "recipes/docker").chmod(0o700)
        for path in (self.root / "config").iterdir():
            path.chmod(0o600)
        (self.root / "config/env").write_text("NETWORK=preview\nNETWORK_MAGIC=42\n")
        test.run(["gen-keys"], cwd=self.root)

    def address(self, key):
        return (self.root / f"credentials/{key}.addr").read_text().strip()

    def configure(self):
        path = self.root / "config/hydra-node.yaml"
        config = yaml.safe_load(path.read_text())
        config.update({"node-id": self.name, "listen": f"127.0.0.1:{self.network}",
                       "advertise": f"127.0.0.1:{self.network}", "api-port": self.api,
                       "monitoring-port": self.monitor})
        config["chain"].update({"contestation-period": 30, "deposit-period": 120,
                                "deposit-activation": 10})
        config["peers"] = []
        for peer in self.test.peers:
            if peer is self:
                continue
            dest = self.root / "peers" / peer.name
            dest.mkdir(parents=True)
            for key in ["hydra.vk", "cardano.vk"]:
                shutil.copy(peer.root / "credentials" / key, dest / key)
            config["peers"].append({
                "address": f"127.0.0.1:{peer.network}",
                "hydra-verification-key": f"../peers/{peer.name}/hydra.vk",
                "cardano-verification-key": f"../peers/{peer.name}/cardano.vk",
            })
        path.write_text(yaml.safe_dump(config))
        self.env = dict(os.environ, CARDANO_NODE_SOCKET_PATH=str(self.test.socket),
                        HYDRA_SCRIPTS_TX_ID=self.test.scripts, HOST_UID=str(os.getuid()),
                        HOST_GID=str(os.getgid()))
        if self.docker:
            (self.root / "state/docker/persistence").mkdir(parents=True)
            override = self.root / "recipes/docker/compose.test.json"
            write_json(override, {"services": {
                "hydra-node": {"network_mode": "host", "volumes": [
                    f"{self.test.work}:/ipc"]},
                "funding": {"volumes": [f"{self.test.work}:/ipc"]},
            }})
            self.test.cleanup.callback(self.test.run, self.compose() + ["down", "--remove-orphans"],
                                       cwd=self.root, env=self.env, timeout=30)

    def compose(self):
        return ["docker", "compose", "-p", self.container,
                "--env-file", "recipes/docker/.env", "--env-file", "config/env",
                "-f", "recipes/docker/compose.yaml", "-f", "recipes/docker/compose.test.json"]

    def distribute(self):
        if self.docker:
            args = self.compose() + ["run", "--rm", "--no-deps", "-T", "funding",
                                     "distribute", "--node-socket", "/ipc/node.socket"]
        else:
            args = ["distribute", "--node-socket", self.test.socket]
        self.test.run(args, cwd=self.root, env=self.env)
        fuel = lovelace(self.test.utxos(self.address("cardano")))
        funds = lovelace(self.test.utxos(self.address("funds")))
        assert fuel >= 2000000 and 0 <= funds - fuel <= 1, "Distribution did not split funds"
        assert fuel + funds < 100000001, "Distribution did not account for its fee"

    def start(self, cleanup):
        if self.docker:
            args = self.compose() + [
                "run", "--rm", "--no-deps", "-T", "--name", self.container, "hydra-node",
                "--config", "/config/hydra-node.yaml", "--persistence-dir", "/state/persistence",
                "--hydra-scripts-tx-id", self.test.scripts, "--node-socket", "/ipc/node.socket",
                "--testnet-magic", "42", "--api-host", "127.0.0.1",
            ]
        else:
            args = ["existing-node", "--tui=false", "--port", self.pc_port, "up", "hydra-node"]
        self.test.start(self.name, args, cwd=self.root, env=self.env, cleanup=cleanup)
        if self.docker:
            cleanup.callback(subprocess.run, ["docker", "rm", "-f", self.container],
                             capture_output=True, timeout=30)

    def http(self, path, value=None):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.api}{path}",
            data=json.dumps(value).encode() if value is not None else None,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.load(response)

    def connect(self, cleanup):
        # Each greeting describes current readiness. Keep the first ready socket;
        # history=no ensures restart checks cannot consume events from the first run.
        def ready():
            connection = websocket.create_connection(f"ws://127.0.0.1:{self.api}/?history=no", timeout=1)
            try:
                greeting = json.loads(connection.recv())
                self.log_event(greeting)
                network = greeting["networkInfo"]
                if (greeting["chainSyncedStatus"] == "InSync"
                        and network["networkConnected"] and any(network["peersInfo"].values())):
                    self.connection = connection
                    cleanup.callback(connection.close)
                    return True
            finally:
                if connection is not self.connection:
                    connection.close()
        self.test.wait(f"{self.name} synchronized and connected to its peer", ready)

    def log_event(self, event):
        with (self.test.logs / f"{self.name}-events.jsonl").open("a") as log:
            log.write(json.dumps(event) + "\n")

    def wait_tag(self, tag):
        def received():
            try:
                event = json.loads(self.connection.recv())
            except websocket.WebSocketTimeoutException:
                return False
            self.log_event(event)
            # Every peer posts IncrementTx; one may lose the race. Both peers must
            # still observe CommitFinalized for this deposit before the timeout.
            if (event["tag"] == "PostTxOnChainFailed"
                    and event["postChainTx"]["tag"] == "IncrementTx"):
                return False
            if event["tag"] in {"PostTxOnChainFailed", "CommandFailed", "InvalidInput"}:
                raise RuntimeError(event)
            return event if event["tag"] == tag else False
        return self.test.wait(f"{self.name}: {tag}", received, timeout=180)

    def send(self, tag):
        self.connection.send(json.dumps({"tag": tag}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe-root", type=Path, required=True)
    parser.add_argument("--hydra-config", type=Path, required=True)
    parser.add_argument("--docker-peer", action="store_true", help="Use the Docker recipe for Bob (Linux)")
    parser.add_argument("--output-dir", type=Path, default=Path("state/validation/lifecycle"))
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hydra-e2e-") as directory:
        cleanup = ExitStack()
        test = Lifecycle(args, Path(directory), cleanup)
        try:
            with cleanup:
                if args.docker_peer:
                    test.run(["docker", "info"], timeout=30)
                test.exercise()
        except BaseException as error:
            test.report.update(status="failed", error=str(error))
            raise
        finally:
            # Replace this runner's previous logs rather than mixing runs.
            if (args.output_dir / "logs").exists():
                shutil.rmtree(args.output_dir / "logs")
            shutil.copytree(test.logs, args.output_dir / "logs")
            write_json(args.output_dir / "result.json", test.report)
            print(f"Evidence: {args.output_dir.resolve() / 'result.json'}", flush=True)


if __name__ == "__main__":
    main()
