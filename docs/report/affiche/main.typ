/*
 Includes
*/
#import "../../template/main.typ": TB_affiche
#show: TB_affiche.with(
  config: (
    global: (
      confidential: false,
      text_lang: "fr"
    ),
    information: (
      title: "Pipeline distribuée d'annotation automatique d'images géospatiales",
      dpt: "TIC",
      filiere: (
        short: "ISC",
        long: "Informatique et systèmes de communication",
      ),
      orientation: "ISC-RS",
      author: (
        name: "Dani Tiago Faria dos Santos",
        feminine_form: false,
      ),
      supervisor: (
        name: "Prof. Bertil Chapuis",
        feminine_form: false,
      ),
      industry_contact: (
        name: "Prof. Bertil Chapuis",
        feminine_form: false,
        industry_name: "HEIG-VD — Institut IICT"
      )
    )
  )
)

= Contexte
Des véhicules équipés de caméras panoramiques parcourent les villes suisses et produisent un corpus visé de 300'000 images de 32 mégapixels. Pour exploiter ces images, chaque objet de la voirie (panneaux, marquages au sol, bouches d'égout) doit être détouré et étiqueté. Un annotateur humain y consacrerait plus de 2'500 heures : l'annotation manuelle intégrale n'est pas envisageable. Le modèle de segmentation SAM3 de Meta sait détecter ces objets à partir d'un simple vocabulaire textuel, sans entraînement préalable, mais une image de cette taille dépasse largement sa fenêtre d'entrée et un seul GPU mettrait des semaines à couvrir le corpus.

= Objectifs
Ce travail conçoit et déploie une pipeline distribuée qui exploite SAM3 tel quel et industrialise tout ce qui l'entoure. Chaque image est découpée en tuiles avec recouvrement afin qu'aucun objet ne soit coupé, l'inférence est répartie sur les GPUs d'un cluster Kubernetes par le framework Ray, et un job interrompu reprend là où il s'était arrêté. Une API REST, une console web, une CLI et des dashboards Grafana permettent de lancer un traitement, de suivre sa progression en temps réel et de diagnostiquer le comportement de chaque GPU. Les détections sont écrites en Parquet, géoréférencées, puis importées comme pré-annotations dans Label Studio où un humain les valide.

#figure(
  image("../images/Schema-Overall.png", width: 72%),
  caption: [Architecture globale de la pipeline.],
)

= Résultats
Le run de production traite les 14'207 images de la ville de Vevey en 10 h 23 sur trois GPUs L40S et produit 423'819 détections. Le passage d'un à trois GPUs accélère le traitement de 2,99×, un gain quasi linéaire : l'inférence par tuiles se parallélise sans contention et le débit croît avec le nombre de GPUs disponibles.

La correction de pré-annotations est 47 % plus rapide que l'annotation manuelle des mêmes images. Annoter une ville coûte ainsi environ 22 CHF de calcul GPU en location cloud pour près de 2'850 CHF de temps humain économisé : chaque franc de calcul en épargne plus de cent.

#figure(
  image("../images/firstOutputLabelStudio.png", width: 88%),
  caption: [Pré-annotations SAM3 importées dans Label Studio.],
)

= Conclusion
La pipeline transforme une tâche de plusieurs mois-homme en un traitement d'une nuit sur l'infrastructure existante, et le seul maillon automatisable de la chaîne de production en est devenu le poste le moins cher. L'architecture reste modulaire : le modèle est confiné dans une seule classe et peut être remplacé par un successeur en quelques dizaines de lignes, le tuilage, la distribution et la reprise n'y touchent pas. Les perspectives portent sur la calibration du recouvrement à partir de la taille réelle des objets et sur la montée en charge du nombre de GPUs.