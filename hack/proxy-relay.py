"""Relays TCP from <listen-host>:<listen-port> to 127.0.0.1:<upstream-port>.

Used by hack/kind-up.sh in sandboxes whose egress proxy listens on loopback
only: kind node containers cannot reach the host's loopback, so they reach the
proxy through this relay on the kind network gateway. Not used in CI.
"""
import asyncio
import sys


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(client_reader, client_writer, upstream_port):
    try:
        up_reader, up_writer = await asyncio.open_connection("127.0.0.1", upstream_port)
    except OSError:
        client_writer.close()
        return
    await asyncio.gather(pipe(client_reader, up_writer), pipe(up_reader, client_writer))


async def main(listen_host, listen_port, upstream_port):
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, upstream_port), listen_host, listen_port
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3])))
