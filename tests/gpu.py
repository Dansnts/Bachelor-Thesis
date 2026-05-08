import warnings

import requests

warnings.filterwarnings("ignore")

PROM = "https://prometheus.iict-rad.iict-heig-vd.in/api/v1/query"
METRICS = [
    ("DCGM_FI_DEV_GPU_UTIL", "%", "{:>6.1f} %"),
    ("DCGM_FI_DEV_FB_USED", "MB", "{:>6.0f} MB"),
    ("DCGM_FI_DEV_POWER_USAGE", "W", "{:>6.1f} W"),
    ("DCGM_FI_DEV_GPU_TEMP", "°C", "{:>6.0f} °C"),
]

for metric, unit, fmt in METRICS:
    r = requests.get(PROM, params={"query": metric}, verify=False)
    print(f"\n === {metric} ===")
    for result in r.json()["data"]["result"]:
        m = result["metric"]
        host = m.get("Hostname", "?")
        gpu = m.get("gpu", "?")
        model = m.get("modelName", "?")
        value = fmt.format(float(result["value"][1]))

        print(f"  {host:<30} gpu{gpu}  {model:<12}  {value}")
