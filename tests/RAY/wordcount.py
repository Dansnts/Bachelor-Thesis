import subprocess
import ray

ray.init("ray://ray-head-svc:10001")
print(f"[INFO] Nodes dans le cluster : {len(ray.nodes())}")

# -- Données : le Zen of Python comme corpus de test
text = subprocess.check_output(["python3", "-c", "import this"]).decode("utf-8")
documents = text.splitlines()

NUM_PARTITIONS = 3

# -- MAP : émet des paires (mot, 1) et les distribue par partition
@ray.remote
def apply_map(docs, num_partitions=NUM_PARTITIONS):
    buckets = [[] for _ in range(num_partitions)]
    for line in docs:
        for word in line.lower().split():
            word = word.strip(".,!?;:'\"")
            if word:
                partition = ord(word[0]) % num_partitions
                buckets[partition].append((word, 1))
    return buckets

# -- REDUCE : additionne les comptes pour chaque partition
@ray.remote
def apply_reduce(*buckets):
    counts = {}
    for bucket in buckets:
        for word, count in bucket:
            counts[word] = counts.get(word, 0) + count
    return counts

# -- Découpage du corpus en partitions
chunk = max(1, len(documents) // NUM_PARTITIONS)
partitions = [
    documents[i * chunk:(i + 1) * chunk]
    for i in range(NUM_PARTITIONS)
]

# -- Lancement des tâches MAP en parallèle
map_results = [
    apply_map.options(num_returns=NUM_PARTITIONS).remote(part)
    for part in partitions
]

# -- Lancement des tâches REDUCE (une par partition)
reduce_results = [
    apply_reduce.remote(*[map_results[m][p] for m in range(NUM_PARTITIONS)])
    for p in range(NUM_PARTITIONS)
]

# -- Agrégation finale
counts = {}
for result in ray.get(reduce_results):
    counts.update(result)

# -- Affichage des 10 mots les plus fréquents
print("\nTop 10 mots :")
for word, count in sorted(counts.items(), key=lambda x: x[1], reverse=True)[:10]:
    print(f"  {word:<20} {count}")

ray.shutdown()
