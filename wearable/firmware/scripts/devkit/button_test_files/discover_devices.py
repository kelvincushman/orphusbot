# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM).

import asyncio
from bleak import BleakScanner

async def main():
     devices = await BleakScanner.discover()
     for d in devices:
         print(d)

asyncio.run(main())