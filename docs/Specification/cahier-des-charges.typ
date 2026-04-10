/*
|              ██
| ████▄ ▄███▄ ▀██▀▀ ▄█▀█▄
| ██ ██ ██ ██  ██   ██▄█▀
| ██ ██ ▀███▀  ██   ▀█▄▄▄
|
| Ce fichier est basé sur du code précédemment écrit par @DACC4 et @samuelroland.
| Dépot original: https://github.com/DACC4/HEIG-VD-typst-template-for-TB
|
*/

#import "macros.typ": *
#import "config.typ": *

#set heading(numbering: none)

#show heading.where(
  level: 1
): it => [
  #pagebreak(weak: true, to: none)
  #v(2.5em)
  #it
  \
]

#show outline.entry.where(
  level: 1
): it => {
  if it.element.func() != heading {
    return it
  }
  v(20pt, weak: true)
  strong(it)
}

#let confidential_text = [
  #if config.global.confidential{
    [Confidentiel]
  }
]

#set page(
  paper: "a4",
  numbering: "1",
  header: context{
    if (not is-first-page(page)) and (not is-title-page(page)) {
      columns(2, [
        #align(left)[#smallcaps([#currentH()])]
        #colbreak()
        #align(right)[#config.information.author.name]
      ])
      hr()
    }
  },
  footer: context{
    if not is-first-page(page){
      hr()
      columns(2, [
        #align(left)[#smallcaps(confidential_text)]
        #colbreak()
        #align(right)[#counter(page).display()]
      ])
    }
  },
  margin: (
    top: 150pt,
    bottom: 150pt,
    x: 1in
  )
)

#set text(font: "New Computer Modern")
#show heading: set block(above: 1.4em, below: 1em)
#show heading.where(level:1): set text(size: 25pt)
#set table.cell(breakable: false)
#show figure: set block(breakable: true)
#show link: underline

#set text(lang: config.global.text_lang)
#set par(leading: 0.55em, spacing: 0.55em, justify: true)

// ─── PAGE DE TITRE ───────────────────────────────────────────────────────────

#image("images/HEIG-VD_logotype-baseline_rouge-cmjn.pdf", width: 6cm)
#v(10%)
#align(center, [#text(size: 14pt, [*Cahier des charges — Travail de Bachelor*])])
#v(4%)
#align(center, [#text(size: 24pt, [*#config.information.title*])])
#v(1%)
#align(center, [#text(size: 16pt, [#config.information.subtitle])])
#v(8%)

#align(left, [
  #block(width: 100%, [
    #table(
      stroke: none,
      columns: (35%, 65%),
      [*#if config.information.author.feminine_form { "Étudiante" } else { "Étudiant" }*], [*#config.information.author.name*],
      [],[],
      [*#if config.information.supervisor.feminine_form { "Superviseure" } else { "Superviseur" }*], [#config.information.supervisor.name],
      [],[],
      [*Département*], [#config.information.departement.long],
      [*Filière*], [#config.information.filiere.long],
      [*Orientation*], [#config.information.orientation.long],
      [],[],
      [*Institut*], [#config.information.industry_contact.industry_name],
      [],[],
      [*Année académique*], [#config.information.academic_years],
      [*Date*], [27 février 2026],
    )
  ])
])

#v(1fr)
#line(length: 100%, stroke: 0.5pt + luma(180))
#v(4pt)
#text(size: 8pt, fill: luma(120))[
  _Ce document a été mis en forme à l'aide d'outils d'intelligence artificielle (Claude, Anthropic). Le contenu, les décisions techniques et les choix architecturaux sont ceux de l'auteur._
]
#pagebreak()

// ─── TABLE DES MATIÈRES ──────────────────────────────────────────────────────

#outline(title: "Table des matières", depth: 3, indent: 15pt)
#pagebreak()

// ─── CONTENU ─────────────────────────────────────────────────────────────────

#set heading(numbering: "1.1")

#include "chapitres/cahier-des-charges.typ"

// ─── BIBLIOGRAPHIE ────────────────────────────────────────────────────────────

#set heading(numbering: none)

#if config.bibliography.content != none {
  bibliography(config.bibliography.content, style: config.bibliography.style, full: true)
}
