-- VIRAL Design — nouveaux vêtements (maillot, haut sport, raglan, ensembles femme)
-- Ajoute leurs noms aux listes autorisées. Sans risque, n'efface rien, peut être relancé.
-- Tant que ce script n'est pas exécuté, l'appli les envoie sans leur nom (rien n'est perdu).
alter table public.events  drop constraint if exists events_garment_check;
alter table public.events  add  constraint events_garment_check
  check (garment is null or garment in ('tshirt','sweat','hoodie','puffer','track','cap','jump','jumphood','maillot','sporth','raglan','sportf','capuchef'));
alter table public.designs drop constraint if exists designs_garment_check;
alter table public.designs add  constraint designs_garment_check
  check (garment is null or garment in ('tshirt','sweat','hoodie','puffer','track','cap','jump','jumphood','maillot','sporth','raglan','sportf','capuchef'));
