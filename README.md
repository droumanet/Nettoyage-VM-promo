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


## Exemple d'usage
./VMtoDelete_promo.sh 

--- 1⃣ Sélection du préfixe de pool ---
  1) SIO-A
  2) SIO-B
  3) DEVOPS
Choisissez le numéro du préfixe de pool : 1
Préfixe sélectionné : SIO-A
--- 2⃣ Découverte des pools Proxmox avec préfixe 'SIO-A' ---
Pools trouvés : SIO-A-01 SIO-A-02 SIO-A-03 SIO-A-04 SIO-A-05 SIO-A-06 SIO-A-07 SIO-A-08 SIO-A-09 SIO-A-10 SIO-A-11 SIO-A-12 SIO-A-13 SIO-A-14 SIO-A-15 SIO-A-16 SIO-A-17 SIO-A-18 SIO-A-19 SIO-A-20 SIO-A-21 SIO-A-22 SIO-A-23 SIO-A-24 SIO-A-25 SIO-A-26 SIO-A-27 SIO-A-28 SIO-A-29 SIO-A-30 SIO-A-31 SIO-A-32 SIO-A-33 SIO-A-34 SIO-A-35 SIO-A-36 
  Scan des pools en cours, patientez...............................................................................................................

--- 3⃣ Liste des VMs/CTs détectés ---
  ❔ [qemu] VMID=103   node=pve03        windows            
  ❔ [qemu] VMID=110   node=pve01        VM 110                   
  ❔ [qemu] VMID=113   node=pve03        machine-opnsense 
  ❔ [qemu] VMID=1001  node=pve01        Formation       
  ❔ [qemu] VMID=1002  node=pve01        SRV-AD         
  ❔ [qemu] VMID=1003  node=pve01        debian                   
  ❔ [qemu] VMID=1004  node=pve01        ubuntu                   
  ❔ [qemu] VMID=1005  node=pve01        opnsense                 
  ❔ [qemu] VMID=1006  node=pve01        windows11                
Entrez les VMID à exclure ou [entrée] pour valider la sélection : 103

  ➖ [qemu] VMID=103   node=pve03        windows            

--- Liste finale des cibles ---
  ➕ [qemu] VMID=110   node=pve01        VM 110                   
  ➕ [qemu] VMID=113   node=pve03        machine-opnsense 
  ➕ [qemu] VMID=1001  node=pve01        Formation       
  ➕ [qemu] VMID=1002  node=pve01        SRV-AD         
  ➕ [qemu] VMID=1003  node=pve01        debian                   
  ➕ [qemu] VMID=1004  node=pve01        ubuntu                   
  ➕ [qemu] VMID=1005  node=pve01        opnsense                 
  ➕ [qemu] VMID=1006  node=pve01        windows11           
Confirmez-vous la suppression de ces ressources ? (oui/non) :
...
