-- VIRAL Design — collection Femme : combinaisons
-- Ajoute les deux nouveaux vêtements aux listes autorisées (statistiques et créations en ligne).
-- Sans risque : n'efface rien, ne modifie aucune donnée existante. Peut être relancé.
-- Tant que ce script n'est pas exécuté, l'appli envoie ces vêtements sans leur nom (rien n'est perdu).

alter table public.events  drop constraint if exists events_garment_check;
alter table public.events  add  constraint events_garment_check
  check (garment is null or garment in ('tshirt','sweat','hoodie','puffer','track','cap','jump','jumphood'));

alter table public.designs drop constraint if exists designs_garment_check;
alter table public.designs add  constraint designs_garment_check
  check (garment is null or garment in ('tshirt','sweat','hoodie','puffer','track','cap','jump','jumphood'));
