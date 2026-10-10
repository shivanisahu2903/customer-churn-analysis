"""
Churn prediction model: customer churn project
------------------------------------------------
Trains Logistic Regression and Random Forest to predict churn, in two versions:

  Model A  "Profile only"  : plan, contract, channel, state, gender, price, age, signup year
  Model B  "Profile + support": Model A plus has_complaint and escalated flags

Columns deliberately EXCLUDED to avoid data leakage (they contain the answer):
  - churn_score          : perfectly separates churners (all churned >= 75, all active <= 64)
  - cancellation_date / cancellation_reason / tenure_days : only exist because the customer left
  - cltv                 : strongly tied to how long the customer stayed (corr -0.52 with churn)

Usage:  python churn_model.py          (needs customer_churn_1.db in the same folder)
"""
import sqlite3
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, confusion_matrix, roc_auc_score, roc_curve
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

DB_PATH = "customer_churn_1.db"
SNAPSHOT = pd.Timestamp("2024-12-31")   # fixed reference date (all cancellations fall in 2024)
RANDOM_STATE = 42

# ---------------------------------------------------------------- load and clean
conn = sqlite3.connect(DB_PATH)
cust = pd.read_sql("SELECT * FROM db_customer", conn)
sub = pd.read_sql("SELECT * FROM db_subscription", conn)
sup = pd.read_sql("SELECT * FROM db_support", conn)
conn.close()

cust["gender"] = cust["gender"].replace({"Men": "Male", "Women": "Female"})
cust["dob"] = pd.to_datetime(cust["dob"])

# latest ticket per customer
sup["complaint_date"] = pd.to_datetime(sup["complaint_date"])
sup = sup.sort_values("complaint_date").drop_duplicates("customerid", keep="last")
sup["escalated"] = (sup["escalations"] == "Y").astype(int)

df = (sub.merge(cust[["customerid", "state", "gender", "dob"]], on="customerid", how="left")
         .merge(sup[["customerid", "escalated"]], on="customerid", how="left"))

df["churn_flag"] = df["cancellation_date"].notna().astype(int)
df["age"] = (SNAPSHOT - df["dob"]).dt.days / 365.25
df["start_year"] = pd.to_datetime(df["subscription_start_date"]).dt.year
df["has_complaint"] = df["escalated"].notna().astype(int)
df["escalated"] = df["escalated"].fillna(0).astype(int)

CAT = ["plan_type", "contract_type", "subscription_type", "state", "gender"]
NUM = ["monthly_charges", "age", "start_year"]
SUPPORT = ["has_complaint", "escalated"]


def evaluate(label, cat, num):
    X, y = df[cat + num], df["churn_flag"]
    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=0.2, random_state=RANDOM_STATE, stratify=y)
    prep = ColumnTransformer([
        ("cat", OneHotEncoder(handle_unknown="ignore"), cat),
        ("num", StandardScaler(), num)])
    models = {
        "Logistic Regression": LogisticRegression(max_iter=1000),
        "Random Forest": RandomForestClassifier(
            n_estimators=300, min_samples_leaf=20, random_state=RANDOM_STATE, n_jobs=-1),
    }
    out = {}
    print(f"\n{'=' * 70}\n{label}\n{'=' * 70}")
    for name, model in models.items():
        pipe = Pipeline([("prep", prep), ("model", model)]).fit(X_tr, y_tr)
        proba = pipe.predict_proba(X_te)[:, 1]
        pred = (proba >= 0.5).astype(int)
        auc = roc_auc_score(y_te, proba)
        print(f"\n{name}: ROC-AUC = {auc:.3f}")
        print(classification_report(y_te, pred, target_names=["Active", "Churned"], digits=3))
        print("Confusion matrix [[TN FP] [FN TP]]:\n", confusion_matrix(y_te, pred))
        out[name] = (pipe, y_te, proba, auc)
    return out


res_a = evaluate("MODEL A: profile features only (no support data)", CAT, NUM)
res_b = evaluate("MODEL B: profile + support features", CAT, NUM + SUPPORT)

# ---------------------------------------------------------------- charts
rf_a = res_a["Random Forest"][0]
names = rf_a["prep"].get_feature_names_out()
imp = (pd.Series(rf_a["model"].feature_importances_, index=names)
         .rename(lambda s: s.split("__")[1].replace("_", " "))
         .sort_values().tail(10))
fig, ax = plt.subplots(figsize=(7, 4.2))
imp.plot.barh(ax=ax, color="#1F8A8A")
ax.set_title("Model A (Random Forest): top 10 churn drivers")
ax.set_xlabel("Feature importance")
plt.tight_layout()
plt.savefig("model_feature_importance.png", dpi=150)

fig, ax = plt.subplots(figsize=(5.2, 4.6))
for label, res, color in [("Model A: profile only", res_a, "#E4572E"),
                          ("Model B: + support data", res_b, "#14213D")]:
    _, y_te, proba, auc = res["Random Forest"]
    fpr, tpr, _ = roc_curve(y_te, proba)
    ax.plot(fpr, tpr, color=color, label=f"{label} (AUC {auc:.2f})")
ax.plot([0, 1], [0, 1], "--", color="grey", lw=1)
ax.set_xlabel("False positive rate"); ax.set_ylabel("True positive rate")
ax.set_title("ROC curves: Random Forest")
ax.legend(loc="lower right")
plt.tight_layout()
plt.savefig("model_roc_curve.png", dpi=150)
print("\nSaved model_feature_importance.png and model_roc_curve.png")
