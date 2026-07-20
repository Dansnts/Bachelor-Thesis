= Conclusion <conclusion>

// 1. Contribution : bien cadrer que le travail EXPLOITE SAM3 tel quel (inférence
//    zero-shot, aucun fine-tuning, aucune modification du modèle — cf. cahier des
//    charges). La contribution du TB est le pipeline distribué autour du modèle :
//    tuilage, distribution Ray/K8s, reprise, observabilité, exploitation des
//    résultats. SAM3 est un composant remplaçable (cf. piste YOLOv8).
//
// 2. Résultats clés à rappeler : 14'207 images en 10 h 23 sur 3 GPUs, speed-up
//    2,99×, détections déterministes, gain de 47 % sur l'annotation humaine.
//
// 3. Coûts : renvoyer à @couts — annoter une ville coûte ≈ 22 CHF en location
//    cloud (Infomaniak L40S 0,70 CHF/h, fournisseur suisse), l'achat d'une carte
//    ne s'amortit qu'entre 11 et 28 runs de corpus (L40S) ou dès 13 runs (A40 à
//    4'000 CHF), le cluster mutualisé existant écrase tout.
//
// 4. Perspectives : étude statistique de la distribution des tailles d'objets
//    pour optimiser le stride, RayJob pour les soumissions concurrentes,
//    montée en charge du nombre de GPUs jusqu'au seuil MinIO.
//
// 5. Améliorations non réalisées faute de temps (à présenter comme faciles,
//    preuve que l'architecture tient sa promesse de modularité) :
//    - Brancher YOLOv8 à la place de SAM3 : tout le code spécifique au modèle
//      est confiné dans la classe Sam3Model de jobCore/worker.py ; le tuilage,
//      la distribution Ray, la reprise et l'export ne connaissent pas SAM3.
//      Il suffirait d'écrire une classe YoloModel exposant la même méthode de
//      détection (image + labels → masques), soit quelques dizaines de lignes
//      avec Ultralytics (un seul appel model.predict, cf. état de l'art).
//      L'effort est minime, seul le temps a manqué en fin de projet. Nuance à
//      mentionner : YOLO n'est pas promptable par texte, il faudrait un modèle
//      entraîné sur les classes visées, là où SAM3 accepte un vocabulaire libre.
