import asyncio, sys
from argparse import Namespace
from frogmouth.app.app import MarkdownViewer

async def main(path, out, width, height, dark):
    app = MarkdownViewer(Namespace(file=[path]))
    async with app.run_test(size=(width, height)) as pilot:
        app.dark = dark
        await pilot.pause(2.0)
        app.save_screenshot(out)

path, out, width, height, dark = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == "dark"
asyncio.run(main(path, out, width, height, dark))
