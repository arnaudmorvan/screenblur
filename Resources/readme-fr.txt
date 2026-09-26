ScreenBlur — flouter une zone de l'écran pendant un partage
═══════════════════════════════════════════════════════════

Vous partagez votre écran et une partie ne regarde personne : une conversation,
un tableau de bord, un nom de client, vos revenus. ScreenBlur pose un masque
dessus. Le masque reste pendant le partage d'écran.

macOS 15 Sequoia ou plus récent. Interface en français.


INSTALLATION
────────────
1. Glissez ScreenBlur dans le dossier Applications (le raccourci est à côté).
2. PREMIER LANCEMENT — double-clic. macOS refusera : « impossible de vérifier
   le développeur ». C'est attendu, l'app n'est pas passée par la notarisation
   d'Apple. Fermez le message, puis :

       Réglages Système → Confidentialité et sécurité → descendre tout en bas
       → « ScreenBlur a été bloqué… » → « Ouvrir quand même »

   (Le vieux contournement par clic droit → « Ouvrir » ne marche plus :
   Apple l'a retiré dans Sequoia.)

   Variante en une ligne dans le Terminal :
       xattr -dr com.apple.quarantine /Applications/ScreenBlur.app

3. Aucune autorisation n'est nécessaire pour commencer. Les styles « Flou
   réglable » et « Mosaïque » demanderont l'enregistrement de l'écran ; les
   deux autres, « Verre dépoli » et « Cache opaque », n'en demandent aucune.


LES DEUX GESTES
───────────────
⌥⇧N  créer ou modifier les zones. Glisser dans le vide trace un cadre ;
     glisser dedans le déplace ; les poignées le redimensionnent ;
     ⌫ supprime ; ⏎ termine.
⌥⇧B  lever ou reposer tout le flou d'un coup, sans rien perdre.

Hors édition, les masques laissent passer les clics : on continue de travailler
dessous.


TROIS FAÇONS DE MASQUER
───────────────────────
• Une ZONE fixe sur l'écran, masquée en permanence.
• Une ZONE RATTACHÉE À UNE APPLICATION : elle ne masque que ce bout-là, sur
  cette application-là, et suit sa fenêtre quand on la déplace. Menu :
  Zones → Zone N → Appliquer cette zone à…
• Une APPLICATION ENTIÈRE, toutes fenêtres comprises.


CE QU'IL FAUT SAVOIR AVANT UNE RÉUNION
──────────────────────────────────────
Un partage de l'ÉCRAN ENTIER montre les masques : ils font partie de l'image
composée par macOS, comme n'importe quelle fenêtre.

Un partage d'UNE SEULE FENÊTRE ne les montre pas. La visioconférence ne capture
alors que cette fenêtre, et aucun outil ne peut s'y insérer — le contenu que
vous croyez masqué passe à l'antenne. Partagez l'écran entier.

Le menu « Aperçu de ce que voient les autres… » prend une image par le même
chemin qu'un partage et l'ouvre dans Aperçu. Trois secondes avant une réunion.


VIE PRIVÉE
──────────
Rien ne sort de votre machine. Aucun compte, aucun réseau, aucune télémétrie.
Les styles par recapture relisent l'écran localement, pour le redessiner flouté,
et n'en gardent rien.


DÉSINSTALLATION
───────────────
Jeter ScreenBlur.app à la corbeille, puis, pour les réglages :
    rm -rf ~/Library/Application\ Support/ScreenBlur
    defaults delete design.axolo.screenblur


─────────────────────────────────────────
Arnaud Morvan — axolo.design
