# Nettoyage de promotion annuel
Dans un lycée, l'usage de VM est périodique et il est normal d'effacer régulièrement les travaux des étudiants lorsqu'ils quittent l'établissement ou simplement au changement d'année.
Le script proposé sur cette forge gère ce nettoyage de manière automatisé (mais sécurisé).
## Prérequis
Avant de pouvoir utiliser le script...
- il faut être sous Proxmox (version testée : 9.1.6)
- il faut utiliser des pools pour les étudiants (dans notre cas, par promotion, SIO-A et SIO-B)
- il faut que les noms de pools utilisent ce préfixe (SIO-A-01, SIO-A-02, etc)
- il faut créer un compte API sur le serveur PBS (version testée : 4.2) et lui associer des droits
- il faut s'assurer que le jq est installé sur le serveur PVE où s'exécute le script

La bonne nouvelle, est que le script traite les VM dans l'ensemble du cluster, donc pas besoin de l'exécuter plusieurs fois.
