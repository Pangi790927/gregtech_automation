"""read_me.py - what the mini ME holds, read through its computer, into data/me-now.txt: the stock
sim.py's mini ME starts from (the audit, 2026-10-04: the sim's ME held the plan's need plus 200,
so it never ran short where the real one did). builders.py writes the same file at each crew
start; this is for a read between runs.

    python 3d-draw/read_me.py          not while a crew holds the mini ME's computer
"""
import asyncio, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import me as mini                                                         # noqa: E402


async def main():
    """One `items` read, written by me.save_stock."""
    link = await mini.me_connect("meserver-read")
    try:
        items = await mini.me_items(link)
    finally:
        await link.close()
    mini.save_stock(items)
    print(f"{len(items)} kinds of item, {sum(items.values())} in all, into {mini.STOCK}")


if __name__ == "__main__":
    asyncio.run(main())
