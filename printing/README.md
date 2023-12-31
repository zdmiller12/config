# Printing

> Directory initially created to host resources for an automated printing routine with the goal of preventing ink cartridges from drying out from infrequent use.

## To Determine Destination Printer Name

> lpstat -p | awk '{print $2}'

command will show the name of the first available printer

### Defaults

`lpstat` may or may not have a default printer assigned, which can be determined by executing

> lpstat -d

---

## Test Images

> From https://www.northlight-images.co.uk/printer-test-images/

### PDI 

![test-image-pdi](./images/PDI-test-image.jpg)

### Fuji sRGB Test Image at 300ppi

![test-image-fuji](./images/frontier_color57s.jpg)
