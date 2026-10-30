# VIRAL Design — mise en route de Supabase

Tant que `supabase-config.js` est vide, l'appli marche comme avant : pas de statistiques, pas de comptes.

## 1. Créer le projet (gratuit)
1. Va sur supabase.com, crée un compte puis **New project**.
2. Région : **West EU (Paris)**. Choisis un mot de passe de base de données fort et garde-le pour toi.

## 2. Créer les tables et les règles
**SQL Editor** → **New query** → colle tout `supabase/schema.sql` → **Run**.

## 3. Configurer la connexion (Authentication)
- **URL Configuration** → **Site URL** : `https://viraldsgn.fr`
  **Redirect URLs** : ajoute `https://viraldsgn.fr/**`
- **Sign In / Providers** → **Email** activé.
- **Emails → SMTP Settings** : le service d'e-mail intégré n'envoie qu'aux membres de ton équipe Supabase, 2 e-mails/heure maximum.
  - Pour **toi seul** (l'admin), il suffit.
  - Pour que **tes utilisateurs** puissent créer un compte, branche un SMTP gratuit (Brevo, Resend…).
- **Emails → Templates** (une fois le SMTP branché) : dans « Magic Link » et « Confirm signup », ajoute `Ton code : {{ .Token }}`.
  Sans ça, la connexion se fait avec le lien de l'e-mail, et ça marche aussi.

## 4. Brancher l'appli
**Project Settings → API Keys** : copie la **Project URL** et la clé **publishable** (ou « anon public »).
Colle-les dans `supabase-config.js`.
⚠ Ne colle jamais la clé `secret` / `service_role` : l'appli la refuse de toute façon.

## 5. Te donner le rôle admin
1. Ouvre `https://viraldsgn.fr/admin/` et connecte-toi avec ton e-mail. Tu verras « Accès refusé » : c'est normal.
2. Dans le **SQL Editor**, lance :
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'TON-EMAIL';
   ```
3. Recharge `/admin/` : le tableau de bord s'affiche.
4. Sur iPhone : Safari → Partager → **Sur l'écran d'accueil**.

## Données et RGPD
- **Statistiques** : identifiant aléatoire par appareil, renouvelé tous les 13 mois. Aucun nom, aucun e-mail, aucune IP stockée, aucun contenu de design. Chaque utilisateur peut les désactiver dans Réglages.
- **Durée de conservation** (recommandation CNIL : 25 mois). Lance de temps en temps :
  `delete from public.events where created_at < now() - interval '25 months';`
- **Comptes** : seul l'e-mail est stocké, chez Supabase. Mentionne-le dans une page « Confidentialité ».
