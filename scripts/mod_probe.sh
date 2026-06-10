#!/bin/bash

echo "---- Rebind UIO ----"
sudo modprobe -r uio_pdrv_genirq
sudo modprobe uio_pdrv_genirq of_id=generic-uio
