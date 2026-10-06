import json
import random
from datetime import datetime

import anthropic
import streamlit as st

SIMULATED_NEWS = {
    "technology": [
        "Major tech companies announce new AI-powered productivity tools aimed at enterprise customers, signaling a shift toward AI-first workplace solutions.",
        "A breakthrough in quantum computing achieves stable qubit operations at room temperature, potentially accelerating commercial quantum applications.",
        "Global cybersecurity spending surges as organizations face increasingly sophisticated AI-driven phishing attacks.",
    ],
    "finance": [
        "Central banks worldwide coordinate on digital currency frameworks, setting stage for interoperable CBDCs by next year.",
        "Venture capital funding rebounds sharply in Q4, with AI and climate-tech startups capturing the majority of deals.",
        "New SEC regulations require enhanced ESG disclosure for publicly traded companies, reshaping corporate reporting.",
    ],
    "health": [
        "Wearable health devices now detect early signs of cardiac events with 95% accuracy, prompting FDA fast-track review.",
        "Global mental health platforms see record adoption as employers expand telehealth benefits for remote workers.",
        "CRISPR-based therapies receive expanded approval for rare genetic disorders, marking a new era in precision medicine.",
    ],
    "sustainability": [
        "Major retailers commit to fully circular supply chains by 2030, driven by consumer demand and regulatory pressure.",
        "Carbon capture technology costs drop 40% year-over-year, making direct air capture commercially viable for the first time.",
        "Electric vehicle sales surpass internal combustion engines in three major European markets for the first time.",
    ],
    "marketing": [
        "Short-form video engagement surpasses all other content formats, with average watch times increasing 60% year-over-year.",
        "Privacy-first advertising gains momentum as major browsers phase out third-party cookies entirely.",
        "Influencer marketing budgets shift toward micro-influencers, with brands reporting 3x higher engagement rates.",
    ],
    "general": [
        "Remote work policies stabilize globally, with hybrid models becoming the dominant workplace standard.",
        "Generative AI tools reshape content creation workflows, with 70% of marketing teams now using AI-assisted copywriting.",
        "Consumer spending shifts toward experiences over goods, with travel and entertainment sectors seeing double-digit growth.",
    ],
}


def fetch_simulated_news(keywords: list[str]) -> list[dict]:
    results = []
    today = datetime.now().strftime("%B %d, %Y")
    for keyword in keywords:
        keyword_lower = keyword.lower()
        matched = False
        for category, headlines in SIMULATED_NEWS.items():
            if keyword_lower in category or category in keyword_lower:
                for headline in headlines:
                    results.append(
                        {"keyword": keyword, "date": today, "summary": headline}
                    )
                matched = True
                break
        if not matched:
            pool = SIMULATED_NEWS["general"]
            chosen = random.sample(pool, min(2, len(pool)))
            for headline in chosen:
                results.append(
                    {"keyword": keyword, "date": today, "summary": headline}
                )
    return results


SYSTEM_PROMPT = """\
You are a strategic media analyst and content planner. You will receive a \
brand identity and a set of today's news summaries related to specific keywords.

Analyze these news items and return a JSON object with exactly this structure:

{
  "topics": [
    {
      "title": "Short topic title",
      "summary": "One-sentence summary of the trending topic",
      "relevance_score": 9,
      "strategic_recommendation": "2-3 sentences on how the brand can leverage this topic",
      "platform_copy": {
        "linkedin": "Professional, insight-driven post (1-2 paragraphs, include a call-to-action)",
        "twitter": "Concise post under 280 characters with relevant hashtags",
        "instagram_tiktok": "Engaging, conversational caption with emojis and hashtags"
      }
    }
  ]
}

Rules:
- Return exactly 3 topics, ranked by relevance to the brand (highest first).
- relevance_score is 1-10, where 10 means perfectly aligned with the brand.
- Tailor every recommendation and piece of copy to the brand's identity.
- Make platform copy ready to post — not templates, but actual usable text.
- Return ONLY the JSON object, no markdown fencing or extra text.\
"""


def analyze_trends(
    client: anthropic.Anthropic,
    brand_identity: str,
    news_items: list[dict],
    model: str,
) -> dict:
    news_text = "\n".join(
        f"- [{item['keyword']}] {item['summary']}" for item in news_items
    )
    user_message = (
        f"Brand Identity: {brand_identity}\n\n"
        f"Today's News Summaries:\n{news_text}"
    )

    response = client.messages.create(
        model=model,
        max_tokens=4096,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_message}],
    )

    raw = response.content[0].text
    return json.loads(raw)


def render_topic_card(topic: dict, index: int) -> None:
    score = topic.get("relevance_score", "N/A")
    with st.expander(f"**#{index + 1} — {topic['title']}** (Relevance: {score}/10)", expanded=(index == 0)):
        st.markdown(f"**Summary:** {topic['summary']}")
        st.markdown(f"**Strategy:** {topic['strategic_recommendation']}")

        st.divider()
        platforms = topic.get("platform_copy", {})

        col1, col2 = st.columns(2)
        with col1:
            st.markdown("**LinkedIn**")
            linkedin = platforms.get("linkedin", "")
            st.text_area("", value=linkedin, height=140, key=f"linkedin_{index}", label_visibility="collapsed")

        with col2:
            st.markdown("**X (Twitter)**")
            twitter = platforms.get("twitter", "")
            st.text_area("", value=twitter, height=140, key=f"twitter_{index}", label_visibility="collapsed")

        st.markdown("**Instagram / TikTok**")
        ig = platforms.get("instagram_tiktok", "")
        st.text_area("", value=ig, height=120, key=f"ig_{index}", label_visibility="collapsed")

        all_copy = f"LinkedIn:\n{linkedin}\n\nX (Twitter):\n{twitter}\n\nInstagram/TikTok:\n{ig}"
        st.code(all_copy, language=None)
        st.caption("Select and copy the text above, or copy from individual fields.")


def main() -> None:
    st.set_page_config(page_title="Media Trend Monitor", page_icon="📡", layout="wide")

    st.title("Media Trend Monitor & Content Planner")
    st.caption("Powered by Claude — Analyze trends and generate platform-ready content")

    with st.sidebar:
        st.header("Configuration")

        api_key = st.text_input(
            "Anthropic API Key",
            type="password",
            help="Your Anthropic API key. Get one at console.anthropic.com.",
        )

        model = st.selectbox(
            "Model",
            options=[
                "claude-sonnet-4-5-20241022",
                "claude-haiku-4-5-20251001",
            ],
            index=0,
            help="Claude 3.5 Sonnet is retired. These are current equivalents.",
        )

        st.divider()

        brand_identity = st.text_area(
            "Brand Identity",
            placeholder="e.g. We are a B2B SaaS company focused on AI-driven HR solutions for mid-market enterprises.",
            height=100,
        )

        keywords_input = st.text_area(
            "Target Keywords (one per line)",
            placeholder="technology\nhealth\nmarketing",
            height=120,
        )

        st.divider()
        st.markdown(
            "**How it works:**\n"
            "1. Enter your brand identity and keywords.\n"
            "2. The app fetches simulated news for those keywords.\n"
            "3. Claude analyzes trends and generates actionable content.\n"
        )

    keywords = [k.strip() for k in keywords_input.strip().splitlines() if k.strip()] if keywords_input else []

    if not keywords:
        st.info("Add at least one keyword in the sidebar to get started.")
        return

    if not brand_identity:
        st.warning("Please describe your brand identity in the sidebar.")
        return

    st.subheader("Tracked Keywords")
    st.write(" · ".join(f"`{kw}`" for kw in keywords))

    if st.button("Analyze Trends & Generate Content", type="primary", use_container_width=True):
        if not api_key:
            st.error("Please enter your Anthropic API key in the sidebar.")
            return

        with st.status("Working...", expanded=True) as status:
            st.write("Fetching today's news summaries...")
            news_items = fetch_simulated_news(keywords)

            st.write(f"Found {len(news_items)} news items. Sending to Claude for analysis...")
            try:
                client = anthropic.Anthropic(api_key=api_key)
                result = analyze_trends(client, brand_identity, news_items, model)
            except anthropic.AuthenticationError:
                st.error("Invalid API key. Please check your key and try again.")
                return
            except anthropic.RateLimitError:
                st.error("Rate limit reached. Please wait a moment and try again.")
                return
            except anthropic.APIStatusError as e:
                st.error(f"API error: {e.message}")
                return
            except json.JSONDecodeError:
                st.error("Failed to parse Claude's response as JSON. Please try again.")
                return

            status.update(label="Analysis complete!", state="complete", expanded=False)

        st.session_state["result"] = result
        st.session_state["news_items"] = news_items

    if "result" in st.session_state:
        result = st.session_state["result"]
        news_items = st.session_state["news_items"]

        col_left, col_right = st.columns([2, 1])
        with col_left:
            st.subheader("Top Trending Topics")
        with col_right:
            st.metric("Topics Analyzed", len(news_items))

        topics = result.get("topics", [])
        for i, topic in enumerate(topics):
            render_topic_card(topic, i)

        with st.expander("Raw News Data"):
            for item in news_items:
                st.markdown(f"- **[{item['keyword']}]** {item['summary']}")

        with st.expander("Raw JSON Response"):
            st.json(result)


if __name__ == "__main__":
    main()
