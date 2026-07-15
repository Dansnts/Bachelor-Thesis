"""Shared Label Studio output format.

One place builds the polygonlabels result dict so the solo driver, the API
import and the ad hoc scripts all emit the same contract. from_name/to_name
must match the labeling XML config, otherwise the polygons show up grey and
unlabelled in Label Studio.
"""


def polygon_result(label, points, width, height, score=None):
    """Return one Label Studio polygonlabels result.

    Arguments :
    label                label of the detected object
    points               polygon points, as percentages of the image size
    width                original image width in pixels
    height               original image height in pixels
    score                detection confidence (0..1), omitted when None
    """
    result = {
        "type": "polygonlabels",
        "from_name": "label",
        "to_name": "image",
        "original_width": width,
        "original_height": height,
        "value": {
            "closed": True,
            "polygonlabels": [label],
            "points": points,
        },
    }
    if score is not None:
        # Label Studio uses the score to sort/colour the pre-annotations
        result["score"] = round(float(score), 4)
    return result
