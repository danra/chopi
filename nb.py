import marimo

__generated_with = "0.25.2"
app = marimo.App(width="full")


@app.cell
def _():
    import marimo as mo

    return (mo,)


@app.cell
def _(mo):
    s = mo.ui.slider(1, 100)
    s
    return (s,)


@app.cell
def _(s):
    s.value ** 2


@app.cell
def _(mo, s):
    mo.md(f"👋 Hello from the agent in its chopi sandbox! The slider is at **{s.value}**, squared: **{s.value ** 2}**.")


if __name__ == "__main__":
    app.run()
