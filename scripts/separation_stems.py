"""Write time-aligned stems with a shared gain so their mix balance is retained."""


def write_stems(source, accompaniment, rate, accompaniment_path, vocal_path=None, vocals=None):
    import numpy as np
    import soundfile as sf

    if accompaniment.shape != source.shape or not np.isfinite(accompaniment).all():
        raise ValueError("Separation produced invalid accompaniment samples")
    gain_scale = max(1.0, float(np.max(np.abs(accompaniment))))
    if vocal_path is not None:
        vocals = source - accompaniment if vocals is None else vocals
        if vocals.shape != source.shape or not np.isfinite(vocals).all():
            raise ValueError("Separation produced invalid vocal samples")
        gain_scale = max(gain_scale, float(np.max(np.abs(vocals))))
        sf.write(vocal_path, vocals / gain_scale, rate, subtype="PCM_24")
    sf.write(accompaniment_path, accompaniment / gain_scale, rate, subtype="PCM_24")
