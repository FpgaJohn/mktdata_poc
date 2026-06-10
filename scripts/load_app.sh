#!/bin/bash

echo "Unloading any existing app..."
sudo xmutil unloadapp

echo "Loading app mktdata_poc"
sudo xmutil loadapp mktdata_poc
